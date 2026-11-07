const std = @import("std");
const vaxis = @import("vaxis");
const client = @import("client.zig");
const upgrade = @import("upgrade.zig");
const ClientTask = @import("ClientTask.zig");
const SessionScreen = @import("SessionScreen.zig");
const SessionTerminal = @import("SessionTerminal.zig");
const TerminalInput = @import("TerminalInput.zig");
const TerminalText = @import("TerminalText.zig");
const TerminalEditor = @import("TerminalEditor.zig");
const View = @import("session_view.zig");
const stderr = @import("stderr.zig");
const Self = @This();

pub const Outcome = enum { unchanged, compatible, incompatible };
const Operation = enum { check, install };

init: std.process.Init,
store: []const u8,
allocator: std.mem.Allocator,
terminal: *SessionTerminal,
stream: *TerminalInput,
interrupted: *client.Cancellation,
screen: *SessionScreen,
task: ClientTask = .{},
phase: std.atomic.Value(upgrade.Phase) = .init(.checking),
operation: Operation = .check,
checked: ?upgrade.Check = null,
result: ?upgrade.Result = null,
cleanup: upgrade.CleanupReceipts = .{},
failure: ?anyerror = null,
outcome: Outcome = .unchanged,
cancelling: bool = false,
close: bool = false,
install_requested: bool = false,
offered: bool = false,
dirty: bool = true,
shown_phase: ?upgrade.Phase = null,

pub fn run(init: std.process.Init, store: []const u8, terminal: *SessionTerminal, interrupted: *client.Cancellation) !Outcome {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const screen = try allocator.create(SessionScreen);
    const original = terminal.screen;
    screen.init(original.backend);
    screen.home = original.home;
    screen.view = .inspection;
    const saved_layout = original.suspendLayout();
    const pump_before = terminal.pump;
    var self: Self = .{ .init = init, .store = store, .allocator = allocator, .terminal = terminal, .stream = &terminal.stream, .interrupted = interrupted, .screen = screen };
    defer self.dispose();
    terminal.screen = screen;
    terminal.pump = .{ .context = &self, .step = pump };
    defer {
        terminal.screen = original;
        terminal.pump = pump_before;
        original.resumeLayout(saved_layout);
    }
    try self.task.start(init.io, &self, work);
    const driven: anyerror!void = self.drive();
    const restored: anyerror!void = if (std.meta.isError(driven)) terminal.finish() else {};
    self.task.cancel();
    const joined = self.task.join();
    var report: std.Io.Writer.Allocating = .init(allocator);
    defer report.deinit();
    const finalized = self.finalize(restored, driven, joined, &report.writer);
    if (report.written().len != 0) stderr.diagnosticBytes(report.written());
    if (finalized.report_failure) |err| stderr.diagnostic("rui: Upgrade exit receipt could not be completely rendered ({s}).\n", .{@errorName(err)});
    return finalized.outcome;
}

const Finalization = struct {
    outcome: anyerror!Outcome,
    report_failure: ?anyerror,
};

fn finalize(self: *const Self, restored: anyerror!void, driven: anyerror!void, joined: anyerror!void, writer: *std.Io.Writer) Finalization {
    std.debug.assert(self.task.thread == null);
    const outcome: anyerror!Outcome = ended: {
        driven catch |err| break :ended err;
        restored catch |err| break :ended err;
        joined catch |err| break :ended err;
        break :ended self.outcome;
    };
    const reported: anyerror!void = if (std.meta.isError(outcome)) self.writeExitReport(restored, joined, writer) else {};
    return .{ .outcome = outcome, .report_failure = if (reported) |_| null else |err| err };
}

fn writeExitReport(self: *const Self, restored: anyerror!void, joined: anyerror!void, writer: *std.Io.Writer) !void {
    if (self.result) |*result| {
        try writer.writeAll("\n");
        try upgrade.writeResult(writer, result);
    }
    try self.cleanup.write(writer);
    restored catch |err| try writer.print("\nrui: Upgrade terminal restoration failed ({s}).\n", .{@errorName(err)});
    const worker_error: ?anyerror = if (joined) |_| self.failure else |err| err;
    if (worker_error) |err| {
        try writer.print("\nrui: Upgrade worker ended with {s}.\n", .{@errorName(err)});
        if (self.result == null and self.operation == .install) try writer.writeAll("Installation failed before publication; selected command and Host unchanged.\n");
    }
}

fn dispose(self: *Self) void {
    std.debug.assert(self.task.thread == null);
    if (self.result) |*result| result.deinit(self.allocator);
    self.result = null;
    if (self.checked) |*checked| checked.deinit(self.allocator);
    self.checked = null;
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

fn drive(self: *Self) !void {
    while (!self.close) {
        if (self.interrupted.stopped.load(.acquire)) return error.InteractiveInterrupted;
        if (self.task.thread != null and self.task.completed()) {
            self.task.join() catch |err| {
                self.failure = err;
            };
            if (self.operation == .install) {
                self.outcome = self.installationOutcome();
                self.phase.store(.finished, .release);
            }
            self.dirty = true;
            try self.document();
        }
        if (self.install_requested) {
            self.install_requested = false;
            self.operation = .install;
            self.cancelling = false;
            self.offered = false;
            self.phase.store(.preparing, .release);
            try self.task.start(self.init.io, self, work);
            self.dirty = true;
        }
        const phase = self.phase.load(.acquire);
        if (self.shown_phase != phase) self.dirty = true;
        const size = self.terminal.geometry();
        if (size.row != self.terminal.size.row or size.col != self.terminal.size.col) self.dirty = true;
        if (self.dirty) try self.draw();
        if (self.close) break;
        _ = try self.step(16);
    }
}

fn installationOutcome(self: *const Self) Outcome {
    std.debug.assert(self.task.thread == null);
    return if (self.result) |*result| if (upgrade.compatible(result)) .compatible else .incompatible else .unchanged;
}

fn document(self: *Self) !void {
    std.debug.assert(self.task.thread == null);
    var raw: std.Io.Writer.Allocating = .init(self.allocator);
    defer raw.deinit();
    try raw.writer.writeAll("Upgrade Rui\n\n");
    if (self.checked) |*checked| try upgrade.writeCheck(&raw.writer, checked);
    try raw.writer.writeAll("\nInstall restarts an already-running supported Host and affects ALL Sessions in this Store.\nActive model/tool work may be interrupted; indeterminate work is never replayed.\nNo running Host means install only; no Host is started.\n\n");
    if (self.result) |*result| try upgrade.writeResult(&raw.writer, result);
    if (self.failure) |err| {
        try raw.writer.print("\nUpgrade {s}: {s}\n", .{ if (self.operation == .check) "check failed" else "operation failed", @errorName(err) });
        if (self.operation == .install) try raw.writer.writeAll("Installation failed before publication; selected command and Host unchanged. Retained files, if any, below.\n");
    }
    try self.cleanup.write(&raw.writer);
    if (self.outcome == .incompatible) try raw.writer.writeAll("\nThis running client cannot safely resume Host requests.\nDraft and recovery handles remain held. Use the selected Rui in a new terminal\nto resume this Session and inspect saved requests; do not resend indeterminate work.\n");
    var safe: std.Io.Writer.Allocating = .init(self.allocator);
    defer safe.deinit();
    var text: TerminalText = .{ .mode = .multiline };
    try text.feed(&safe.writer, raw.written());
    try text.finish(&safe.writer);
    self.screen.browsing.text.clear();
    try self.screen.browsing.text.append(safe.written());
    self.screen.browsing.scroll.scroll.y = 0;
    self.screen.browsing.blank_tail = 0;
}

fn installable(self: *const Self) bool {
    return self.task.thread == null and self.operation == .check and self.failure == null and !self.cancelling and
        if (self.checked) |*checked| upgrade.canInstall(checked) else false;
}

fn draw(self: *Self) !void {
    self.dirty = false;
    self.offered = false;
    if (self.checked == null and self.failure == null) {
        self.screen.browsing.text.clear();
        try self.screen.browsing.text.append("Upgrade Rui\n\nChecking the published stable release and local installation.\nThis check does not install or start a Host.\n");
    }
    const phase = self.phase.load(.acquire);
    const hint = if (self.task.thread != null)
        (if (self.cancelling) "Cancellation requested; waiting for the actual outcome" else "esc Cancel")
    else if (self.installable()) "enter Install · esc Cancel · pgup/pgdn Scroll" else "esc Return · pgup/pgdn Scroll";
    const live: View.Live = .{};
    _ = try self.terminal.redraw("", 0, .{ .status = phaseText(phase), .notice = hint }, &live);
    self.shown_phase = phase;
    // A return accepted while writing hands input back at delivery, not
    // after a freshness read belonging to the next owner.
    if (self.close) return;
    for (0..1024) |_| {
        if (!try self.step(0)) {
            self.offered = self.installable() and !self.screen.stale() and self.stream.pending() == .none;
            break;
        }
        if (self.close) break;
    }
}

fn phaseText(phase: upgrade.Phase) []const u8 {
    return switch (phase) {
        .checking => "Read-only check",
        .preparing => "Installation: preparing and verifying download",
        .publishing => "Installation: publishing; cancellation is not rollback",
        .stopping => "Activation: stopping the observed Host",
        .awaiting_retirement => "Activation: waiting for Host retirement",
        .starting => "Activation: starting the installed build",
        .verifying => "Activation: verifying readiness and protocol",
        .finished => "Upgrade result",
    };
}

fn pump(raw: *anyopaque) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.interrupted.stopped.load(.acquire)) return error.InteractiveInterrupted;
    // A panel-local return does not abandon the invocation's frozen frame.
    // Signals and real input/output errors still abort through their owners.
    if (self.close) return;
    _ = try self.step(if (self.terminal.writing) 0 else 16);
}

fn step(self: *Self, wait: i32) !bool {
    const read = self.terminal.next(self.init.io, wait) catch |err| switch (err) {
        error.InputDeadline => {
            try self.input(try self.stream.expire());
            return true;
        },
        else => return err,
    };
    if (read) |byte| {
        var decoded = self.stream.feed(byte.byte, byte.at);
        while (decoded != .none) : (decoded = self.stream.next()) try self.input(decoded);
        return true;
    }
    return false;
}

fn input(self: *Self, decoded: TerminalInput.Decoded) !void {
    switch (decoded) {
        .report => |report| switch (report) {
            .width => |method| self.terminal.widthReported(method),
            .alternate_scroll_reset => try self.terminal.enableAlternateScroll(),
            .focus => |focused| self.terminal.focused = focused,
            .program_status => _ = self.terminal.answered(.program_status),
            .device_attributes => _ = self.terminal.answered(.device_attributes),
        },
        .event => |event| {
            if (event.pasted or event.event != .key_press) return;
            const key = event.event.key_press;
            if (key.codepoint == vaxis.Key.escape or (key.mods.ctrl and key.codepoint == 'c') or key.codepoint == 3) {
                self.offered = false;
                if (self.task.thread != null) {
                    self.cancelling = true;
                    self.task.cancel();
                } else self.close = true;
            } else if (TerminalEditor.isEnter(key) and self.offered and self.installable()) {
                self.offered = false;
                self.install_requested = true;
            } else if (key.codepoint == vaxis.Key.page_up or key.codepoint == vaxis.Key.page_down) {
                _ = self.screen.browse(key.codepoint == vaxis.Key.page_down, true);
            }
        },
        .none, .invalid => {},
    }
    self.dirty = true;
}

test "upgrade panel phases distinguish publication from activation and cancellation" {
    try std.testing.expect(std.mem.indexOf(u8, phaseText(.checking), "Read-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, phaseText(.publishing), "not rollback") != null);
    for ([_]upgrade.Phase{ .stopping, .awaiting_retirement, .starting, .verifying }) |phase|
        try std.testing.expect(std.mem.startsWith(u8, phaseText(phase), "Activation:"));
}

test "upgrade panel Escape requests cancellation and waits for the joined outcome at every phase" {
    const Gate = struct {
        entered: std.Io.Event = .unset,
        release: std.Io.Event = .unset,

        fn run(raw: *anyopaque, task: *ClientTask) !void {
            const gate: *@This() = @ptrCast(@alignCast(raw));
            gate.entered.set(task.io);
            gate.release.waitUncancelable(task.io);
            if (task.cancellation.stopped.load(.acquire)) return error.Cancelled;
            return error.TestUnexpectedResult;
        }
    };
    for (std.enums.values(upgrade.Phase)) |phase| {
        var gate: Gate = .{};
        var self: Self = .{ .init = undefined, .store = "unused", .allocator = std.testing.allocator, .terminal = undefined, .stream = undefined, .interrupted = undefined, .screen = undefined, .phase = .init(phase) };
        try self.task.start(std.testing.io, &gate, Gate.run);
        defer {
            gate.release.set(std.testing.io);
            self.task.join() catch |err| std.debug.assert(err == error.Cancelled);
        }
        gate.entered.waitUncancelable(std.testing.io);
        try self.input(.{ .event = .{ .event = .{ .key_press = .{ .codepoint = vaxis.Key.escape } }, .pasted = true } });
        try std.testing.expect(!self.task.cancellation.stopped.load(.acquire));
        try self.input(.{ .event = .{ .event = .{ .key_press = .{ .codepoint = vaxis.Key.escape } }, .pasted = false } });
        try std.testing.expect(self.task.cancellation.stopped.load(.acquire));
        try std.testing.expect(self.cancelling and !self.close);
        try std.testing.expectEqual(Outcome.unchanged, self.outcome);
        gate.release.set(std.testing.io);
        try std.testing.expectError(error.Cancelled, self.task.join());
        try std.testing.expectEqual(Outcome.unchanged, self.outcome);
    }
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
            .terminal = undefined,
            .stream = undefined,
            .interrupted = undefined,
            .screen = undefined,
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
        self.dispose();
        try std.testing.expect(capture.wiped);
        try std.testing.expectEqual(@as(usize, 1), capture.freed);
        try std.testing.expect(self.result == null and self.checked == null);
        self.dispose();
        try std.testing.expectEqual(@as(usize, 1), capture.freed);
    }
}

const test_checked: upgrade.Check = .{
    .candidate = .{ .version = .{ .schema = 99, .patch = 1 }, .tag = "v0.99.1", .archive_name = "synthetic", .archive_url = "synthetic", .checksum_url = "synthetic", .sha256 = @splat(0) },
    .selected = .{ .released = .{ .build = "/synthetic/build", .version = .{ .schema = 99, .patch = 0 } } },
    .host = .absent,
    .home = "/synthetic/home",
    .store = "/synthetic/store",
    .running_executable = "/synthetic/rui",
};

test "upgrade panel accepts semantic Enter only when typed pressed offered and installable" {
    const Case = struct { key: vaxis.Key, accepts: bool = false };
    const cases = [_]Case{
        .{ .key = .{ .codepoint = vaxis.Key.enter }, .accepts = true },
        .{ .key = .{ .codepoint = 'j', .mods = .{ .ctrl = true } }, .accepts = true },
        .{ .key = .{ .codepoint = vaxis.Key.enter, .mods = .{ .shift = true }, .text = "\r" } },
        .{ .key = .{ .codepoint = vaxis.Key.enter, .mods = .{ .alt = true }, .text = "\r" } },
        .{ .key = .{ .codepoint = vaxis.Key.enter, .mods = .{ .ctrl = true } } },
        .{ .key = .{ .codepoint = 'j', .mods = .{ .ctrl = true, .shift = true }, .text = "j" } },
        .{ .key = .{ .codepoint = 'j', .mods = .{ .alt = true } } },
        .{ .key = .{ .codepoint = 'j' } },
        .{ .key = .{ .codepoint = vaxis.Key.enter, .mods = .{ .super = true } } },
        .{ .key = .{ .codepoint = vaxis.Key.enter, .mods = .{ .hyper = true } } },
        .{ .key = .{ .codepoint = vaxis.Key.enter, .mods = .{ .meta = true } } },
    };
    for (cases) |case| {
        for ([_]bool{ false, true }) |pasted| {
            for ([_]bool{ false, true }) |released| {
                for ([_]bool{ false, true }) |offered| {
                    for ([_]bool{ false, true }) |eligible| {
                        var checked = test_checked;
                        if (!eligible) checked.selected = .ineligible;
                        var self: Self = .{ .init = undefined, .store = "unused", .allocator = std.testing.allocator, .terminal = undefined, .stream = undefined, .interrupted = undefined, .screen = undefined, .checked = checked, .offered = offered };
                        try self.input(.{ .event = .{ .event = if (released) .{ .key_release = case.key } else .{ .key_press = case.key }, .pasted = pasted } });
                        const accepted = case.accepts and !pasted and !released and offered and eligible;
                        try std.testing.expectEqual(accepted, self.install_requested);
                        try std.testing.expectEqual(offered and !accepted, self.offered);
                    }
                }
            }
        }
    }
}

test "upgrade panel accepts CR LF and exact Kitty ctrl-J through the terminal decoder without accepting preprompt input" {
    for ([_][]const u8{ "\r", "\n", "\x1b[13u", "\x1b[106;5u" }) |sequence| {
        for ([_]bool{ false, true }) |offered| {
            var stream: TerminalInput = .{};
            var self: Self = .{ .init = undefined, .store = "unused", .allocator = std.testing.allocator, .terminal = undefined, .stream = &stream, .interrupted = undefined, .screen = undefined, .checked = test_checked, .offered = offered };
            for (sequence) |byte| {
                var decoded = stream.feed(byte, 0);
                while (decoded != .none) : (decoded = stream.next()) try self.input(decoded);
            }
            try std.testing.expectEqual(offered, self.install_requested);
            try std.testing.expect(!self.offered);
        }
    }
}

const test_installed_result: upgrade.Result = .{
    .installation = .{ .installed = .{ .operation_build = "/synthetic/installed", .selected_after = "/synthetic/installed" } },
    .activation = .cancelled,
    .store = "/synthetic/store",
};

test "upgrade panel failing exits report the actual joined installation receipt and preserve the primary failure" {
    const Case = struct { restored: anyerror!void = {}, driven: anyerror!void, joined: anyerror!void = {}, failure: anyerror };
    const cases = [_]Case{
        .{ .driven = error.TerminalCleanupFailed, .failure = error.TerminalCleanupFailed },
        .{ .driven = error.InteractiveInterrupted, .failure = error.InteractiveInterrupted },
        .{ .restored = error.TerminalRestoreFailed, .driven = error.InteractiveInterrupted, .joined = error.Cancelled, .failure = error.InteractiveInterrupted },
    };
    const expected =
        "\nInstalled Rui. Complete build: /synthetic/installed\n" ++
        "Activation: cancelled after installation; publication was not rolled back.\n" ++
        "Store: /synthetic/store\n" ++
        "Next: inspect rui host status --store $'/synthetic/store'. Do not restore/reset the Store or replay uncertain requests.\n";
    for (cases) |case| {
        const self: Self = .{ .init = undefined, .store = "unused", .allocator = std.testing.allocator, .terminal = undefined, .stream = undefined, .interrupted = undefined, .screen = undefined, .operation = .install, .result = test_installed_result };
        var bytes: [2048]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        const finalized = self.finalize(case.restored, case.driven, case.joined, &writer);
        try std.testing.expectError(case.failure, finalized.outcome);
        try std.testing.expect(finalized.report_failure == null);
        if (std.meta.isError(case.joined)) {
            try std.testing.expectEqualStrings(expected ++ "\nrui: Upgrade terminal restoration failed (TerminalRestoreFailed).\n\nrui: Upgrade worker ended with Cancelled.\n", writer.buffered());
        } else try std.testing.expectEqualStrings(expected, writer.buffered());
        try std.testing.expect(self.result != null);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "No completed installation receipt") == null);
    }
}

test "upgrade panel receipt rendering failure never replaces the primary terminal failure" {
    const self: Self = .{ .init = undefined, .store = "unused", .allocator = std.testing.allocator, .terminal = undefined, .stream = undefined, .interrupted = undefined, .screen = undefined, .operation = .install, .result = test_installed_result };
    var writer = std.Io.Writer.fixed(&.{});
    const finalized = self.finalize({}, error.TerminalCleanupFailed, {}, &writer);
    try std.testing.expectError(error.TerminalCleanupFailed, finalized.outcome);
    try std.testing.expectEqual(error.WriteFailed, finalized.report_failure.?);
    try std.testing.expect(self.result != null);
}

test "upgrade panel retains copied cleanup facts in its joined document and restored exit report" {
    const screen = try std.testing.allocator.create(SessionScreen);
    defer std.testing.allocator.destroy(screen);
    var env = try std.testing.environ.createMap(std.testing.allocator);
    defer env.deinit();
    try SessionScreen.Test.init(screen, std.testing.io, &env, false);
    defer SessionScreen.Test.deinit(screen);
    inline for (.{ .preparation, .publication, .disposal }) |phase| {
        screen.init(screen.backend);
        const primary: ?anyerror = if (phase == .disposal) null else error.ReleaseChecksumMismatch;
        var self: Self = .{ .init = undefined, .store = "unused", .allocator = std.testing.allocator, .terminal = undefined, .stream = undefined, .interrupted = undefined, .screen = screen, .operation = .install, .result = if (phase == .disposal) test_installed_result else null, .failure = primary };
        var source_path = "/synthetic/retained-stage".*;
        const reporter = self.cleanup.reporter(phase);
        reporter.report(reporter.context, .{ .primary = primary, .secondary = error.AccessDenied, .retained_path = &source_path });
        @memset(&source_path, 'x');
        try self.document();
        const document_text = screen.browsing.text.text();
        try std.testing.expect(std.mem.indexOf(u8, document_text, "AccessDenied") != null);
        try std.testing.expect(std.mem.indexOf(u8, document_text, "$'/synthetic/retained-stage'") != null);
        if (primary != null) try std.testing.expect(std.mem.indexOf(u8, document_text, "ReleaseChecksumMismatch") != null);
        var bytes: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        const finalized = self.finalize({}, error.InteractiveInterrupted, {}, &writer);
        try std.testing.expectError(error.InteractiveInterrupted, finalized.outcome);
        try std.testing.expect(finalized.report_failure == null);
        const report_text = writer.buffered();
        try std.testing.expect(std.mem.indexOf(u8, report_text, "AccessDenied") != null);
        const retained_at = std.mem.indexOf(u8, report_text, "$'/synthetic/retained-stage'").?;
        if (primary != null) {
            try std.testing.expect(std.mem.indexOf(u8, report_text, "ReleaseChecksumMismatch") != null);
        } else {
            const installed_at = std.mem.indexOf(u8, report_text, "Installed Rui. Complete build: /synthetic/installed").?;
            try std.testing.expect(installed_at < retained_at);
        }
        try std.testing.expect(std.mem.indexOf(u8, report_text, "No completed installation receipt") == null);
        try std.testing.expect(self.cleanup.any());
    }
}

test "upgrade panel prepublication errors retain unchanged Host access while actual activation outcomes govern compatibility" {
    for ([_]anyerror{ error.ReleaseChecksumMismatch, error.Cancelled, error.AccessDenied }) |failure| {
        const self: Self = .{ .init = undefined, .store = "unused", .allocator = std.testing.allocator, .terminal = undefined, .stream = undefined, .interrupted = undefined, .screen = undefined, .operation = .install, .failure = failure };
        try std.testing.expectEqual(Outcome.unchanged, self.installationOutcome());
        var bytes: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        const finalized = self.finalize({}, error.InteractiveInterrupted, failure, &writer);
        try std.testing.expectError(error.InteractiveInterrupted, finalized.outcome);
        try std.testing.expect(finalized.report_failure == null);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Installation failed before publication; selected command and Host unchanged.") != null);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "incomplete") == null);
    }
    const Activation = @FieldType(upgrade.Result, "activation");
    const Case = struct { activation: Activation, outcome: Outcome };
    for ([_]Case{
        .{ .activation = .cancelled, .outcome = .compatible },
        .{ .activation = .not_needed, .outcome = .compatible },
        .{ .activation = .{ .failed = .starting }, .outcome = .incompatible },
        .{ .activation = .{ .unconfirmed = .verifying }, .outcome = .incompatible },
        .{ .activation = .replacement_observed, .outcome = .incompatible },
    }) |case| {
        var result = test_installed_result;
        result.activation = case.activation;
        const self: Self = .{ .init = undefined, .store = "unused", .allocator = std.testing.allocator, .terminal = undefined, .stream = undefined, .interrupted = undefined, .screen = undefined, .operation = .install, .result = result };
        try std.testing.expectEqual(case.outcome, self.installationOutcome());
    }
}

test "upgrade panel paints with the invocation backend and decoder before offering any installation" {
    var env = try std.testing.environ.createMap(std.testing.allocator);
    defer env.deinit();
    const original = try std.testing.allocator.create(SessionScreen);
    defer std.testing.allocator.destroy(original);
    try SessionScreen.Test.init(original, std.testing.io, &env, false);
    defer SessionScreen.Test.deinit(original);
    const panel = try std.testing.allocator.create(SessionScreen);
    defer std.testing.allocator.destroy(panel);
    panel.init(original.backend);
    panel.view = .inspection;
    const saved = original.suspendLayout();
    var keys: [2]c_int = undefined;
    if (std.c.pipe(&keys) != 0) return error.SystemResources;
    defer for (keys) |fd| {
        _ = std.c.close(fd);
    };
    var output: [2]c_int = undefined;
    if (std.c.pipe(&output) != 0) return error.SystemResources;
    defer for (output) |fd| {
        _ = std.c.close(fd);
    };
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    for (keys ++ output) |fd| {
        const flags = std.c.fcntl(fd, std.c.F.GETFL);
        if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | nonblock) < 0) return error.SystemResources;
    }
    var terminal: SessionTerminal = .{ .original = undefined, .flags = .{ 0, 0 }, .input = keys[0], .output = output[1], .screen = panel };
    var cancellation: client.Cancellation = .{};
    var self: Self = .{ .init = undefined, .store = "/synthetic/store", .allocator = std.testing.allocator, .terminal = &terminal, .stream = &terminal.stream, .interrupted = &cancellation, .screen = panel, .checked = test_checked };
    self.init.io = std.testing.io;
    terminal.pump = .{ .context = &self, .step = pump };
    try self.document();
    try self.input(.{ .event = .{ .event = .{ .key_press = .{ .codepoint = vaxis.Key.enter } }, .pasted = true } });
    try std.testing.expect(!self.offered and !self.install_requested);
    try self.draw();
    var bytes: [64 * 1024]u8 = undefined;
    try std.testing.expect(std.c.read(output[0], &bytes, bytes.len) > 0);
    try std.testing.expect(self.offered and !self.install_requested);
    const at = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    _ = terminal.stream.feed('\x1b', at);
    _ = terminal.stream.feed('[', at);
    try self.input(.{ .event = .{ .event = .{ .key_press = .{ .codepoint = vaxis.Key.escape } }, .pasted = false } });
    try std.testing.expect(self.close and !self.install_requested and self.task.thread == null);
    terminal.screen = original;
    terminal.pump = null;
    original.resumeLayout(saved);
    try std.testing.expect(original.backend == panel.backend and original.backend.idle());
    try std.testing.expect(self.stream == &terminal.stream);
    try std.testing.expectEqual(TerminalInput.Pending.incomplete, terminal.stream.pending());
}

/// Synthetic terminal credit only: no worker, network, installer or Host.
const HeldPanel = struct {
    self: Self,
    screen: *SessionScreen,
    env: std.process.Environ.Map,
    pipes: [2][2]c_int,
    terminal: SessionTerminal,
    cancellation: client.Cancellation = .{},

    fn create() !*@This() {
        const held = try std.testing.allocator.create(@This());
        errdefer std.testing.allocator.destroy(held);
        var pipes: [2][2]c_int = undefined;
        var opened: usize = 0;
        errdefer for (pipes[0..opened]) |pipe| for (pipe) |fd| {
            _ = std.c.close(fd);
        };
        for (&pipes) |*pipe| {
            if (std.c.pipe(pipe) != 0) return error.SystemResources;
            opened += 1;
        }
        const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
        for (pipes) |pipe| for (pipe) |fd| {
            const flags = std.c.fcntl(fd, std.c.F.GETFL);
            if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | nonblock) < 0) return error.SystemResources;
        };
        const screen = try std.testing.allocator.create(SessionScreen);
        errdefer std.testing.allocator.destroy(screen);
        var env = try std.testing.environ.createMap(std.testing.allocator);
        errdefer env.deinit();
        held.* = .{ .self = undefined, .screen = screen, .env = env, .pipes = pipes, .terminal = .{ .original = undefined, .flags = .{ 0, 0 }, .input = pipes[0][0], .output = pipes[1][1], .screen = screen } };
        try SessionScreen.Test.init(screen, std.testing.io, &held.env, false);
        screen.view = .inspection;
        held.self = .{ .init = undefined, .store = "/synthetic/store", .allocator = std.testing.allocator, .terminal = &held.terminal, .stream = &held.terminal.stream, .interrupted = &held.cancellation, .screen = screen, .checked = test_checked };
        held.self.init.io = std.testing.io;
        return held;
    }
    fn destroy(held: *@This()) void {
        for (held.pipes) |pipe| for (pipe) |fd| {
            _ = std.c.close(fd);
        };
        SessionScreen.Test.deinit(held.screen);
        std.testing.allocator.destroy(held.screen);
        held.env.deinit();
        std.testing.allocator.destroy(held);
    }
    fn hold(held: *@This(), input_bytes: []const u8) !void {
        held.screen.backend.invalidate();
        try std.testing.expectEqual(@as(isize, @intCast(input_bytes.len)), std.c.write(held.pipes[0][1], input_bytes.ptr, input_bytes.len));
        var block: [4096]u8 = @splat('x');
        while (std.c.write(held.pipes[1][1], &block, block.len) > 0) {}
    }
    fn credit(held: *@This()) void {
        var sink: [65536]u8 = undefined;
        while (std.c.read(held.pipes[1][0], &sink, sink.len) > 0) {}
    }
};

test "upgrade panel width reports defer policy changes until the frozen frame ends" {
    const held = try HeldPanel.create();
    defer held.destroy();
    const Credit = struct {
        held: *HeldPanel,
        observed: bool = false,
        fn step(raw: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try pump(&self.held.self);
            if (self.held.terminal.pending_width != null) {
                try std.testing.expect(self.held.terminal.writing and !self.held.screen.backend.idle());
                try std.testing.expectEqual(vaxis.gwidth.Method.wcwidth, self.held.screen.backend.widthMethod());
                try std.testing.expect(!self.held.screen.ticket.?.delivered);
                self.observed = true;
                self.held.credit();
            }
        }
    };
    var credit: Credit = .{ .held = held };
    held.terminal.pump = .{ .context = &credit, .step = Credit.step };
    try held.hold("\x1b[?2027;3$y");
    try held.self.draw();
    try std.testing.expect(credit.observed);
    try std.testing.expectEqual(vaxis.gwidth.Method.unicode, held.screen.backend.widthMethod());
    try std.testing.expect(held.terminal.pending_width == null and held.screen.backend.idle());
    try std.testing.expect(!held.self.offered and !held.self.install_requested and held.screen.stale());
    held.credit();
    try held.self.draw();
    try std.testing.expect(held.self.offered and !held.screen.stale());
    try held.self.input(.{ .event = .{ .event = .{ .key_press = .{ .codepoint = vaxis.Key.enter } }, .pasted = true } });
    try std.testing.expect(!held.self.install_requested);
    try held.self.input(.{ .event = .{ .event = .{ .key_press = .{ .codepoint = vaxis.Key.enter } }, .pasted = false } });
    try std.testing.expect(held.self.install_requested and !held.self.offered);
    // Do not drive the synthetic admission: no installation worker is started.
    try std.testing.expect(held.self.task.thread == null);
}

test "upgrade panel benign close finishes the frame before handing queued input back" {
    const held = try HeldPanel.create();
    defer held.destroy();
    const tail = "z\x03\x1b[";
    const Credit = struct {
        held: *HeldPanel,
        credited: bool = false,
        fn step(raw: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try pump(&self.held.self);
            if (!self.held.self.close or self.credited) return;
            try std.testing.expect(self.held.terminal.writing and !self.held.screen.ticket.?.delivered);
            try std.testing.expectEqual(@as(isize, tail.len), std.c.write(self.held.pipes[0][1], tail, tail.len));
            self.credited = true;
            self.held.credit();
        }
    };
    var credit: Credit = .{ .held = held };
    held.terminal.pump = .{ .context = &credit, .step = Credit.step };
    const backend = held.screen.backend;
    const stream = held.self.stream;
    try held.hold("\x1b[27u");
    try held.self.drive();
    try std.testing.expect(credit.credited and held.self.close);
    try std.testing.expect(!held.self.offered and !held.self.install_requested and held.self.task.thread == null);
    try std.testing.expect(backend.idle() and held.screen.backend == backend and stream == &held.terminal.stream);
    var remaining: [16]u8 = undefined;
    const n = std.c.read(held.pipes[0][0], &remaining, remaining.len);
    try std.testing.expectEqual(@as(isize, tail.len), n);
    try std.testing.expectEqualStrings(tail, remaining[0..@intCast(n)]);
    try std.testing.expectEqual(TerminalInput.Pending.none, stream.pending());
    for (tail[0..2], 0..) |byte, i| {
        const decoded = stream.feed(byte, 0);
        try std.testing.expect(decoded == .event);
        try std.testing.expect(decoded.event.event.key_press.matchExact(if (i == 0) 'z' else 'c', if (i == 0) .{} else .{ .ctrl = true }));
    }
    for (tail[2..]) |byte| _ = stream.feed(byte, 0);
    try std.testing.expectEqual(TerminalInput.Pending.incomplete, stream.pending());
    const up = stream.feed('A', 0);
    try std.testing.expect(up == .event and up.event.event.key_press.matchExact(vaxis.Key.up, .{}));
    // Returning the same healthy grid can draw again without a new decoder.
    held.terminal.pump = null;
    held.screen.invalidateLayout();
    _ = try held.terminal.redraw("", 0, .{}, &.{});
    try std.testing.expect(backend.idle() and held.screen.backend == backend);
}

test "upgrade panel invocation interruption and real pump failures never deliver a held frame" {
    for ([_]bool{ false, true }) |interrupted| {
        const held = try HeldPanel.create();
        defer held.destroy();
        const Failure = struct {
            held: *HeldPanel,
            interrupted: bool,
            fn step(raw: *anyopaque) !void {
                const self: *@This() = @ptrCast(@alignCast(raw));
                self.held.self.close = true;
                if (!self.interrupted) return error.TerminalReadFailed;
                self.held.cancellation.requestStop();
                try pump(&self.held.self);
            }
        };
        var failure: Failure = .{ .held = held, .interrupted = interrupted };
        held.terminal.pump = .{ .context = &failure, .step = Failure.step };
        try held.hold("");
        try std.testing.expectError(if (interrupted) error.InteractiveInterrupted else error.TerminalReadFailed, held.self.drive());
        try std.testing.expect(!held.screen.backend.idle() and !held.screen.ticket.?.delivered);
        try std.testing.expect(!held.self.offered and !held.self.install_requested);
    }
}
