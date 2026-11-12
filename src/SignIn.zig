//! One sign-in interaction and its joined UI worker. No Host thread or
//! credential implementation belongs to the screen.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const core = @import("sign_in.zig");
const ClientTask = @import("ClientTask.zig");
const api_key = @import("api_key.zig");
const codex_auth = @import("codex_auth.zig");
const provider_login = @import("provider_login.zig");
const preferences = @import("preferences.zig");
const selection = @import("new_session_selection.zig");
const Footer = @import("widgets/Footer.zig");
const choice_row = @import("choice_row.zig");
const ConversationViewport = @import("ConversationViewport.zig");
const Self = @This();
const host_launch = @import("host_launch.zig");

pub const Activation = struct {
    binding: selection.Binding,
    store: @import("protocol.zig").Bounded(@import("protocol.zig").max_store_bytes),
    default_failed: bool = false,
    launch: ?host_launch.Result = null,
};
pub const Activate = *const fn (std.process.Init, selection.Intent) anyerror!Activation;
pub const Ready = *const fn (std.process.Init) core.Readinesses;
const Published = struct { defaults: anyerror!void, activation: anyerror!Activation };
const Outcome = union(enum) { cancelled, failed: anyerror, published: Published };
const Presentation = union(enum) { screen: *vxfw.EventContext, departure: *std.Io.Writer };
state: core.State = .{},
init: ?std.process.Init = null,
selectors: selection.Intent = .{},
activate: ?Activate = null,
ready: ?Ready = null,
userdata: ?*anyopaque = null,
on_done: ?*const fn (*anyopaque, *vxfw.EventContext, Activation) anyerror!void = null,
on_close: ?*const fn (*anyopaque, *vxfw.EventContext) anyerror!void = null,
style: vaxis.Style = .{},
quiet: vaxis.Style = .{},
key: api_key.Key = .{},
key_rejected: bool = false,
/// Whether the screen shows the list, whose header names the app; without
/// an answer the page names it itself.
list_visible: ?*const fn (*anyopaque) bool = null,
pasting: bool = false,
task: ClientTask = .{},
/// Cancellation and publication claim the same gate, as the CLI does. Once
/// publication wins, Escape cannot claim that the saved sign-in was undone.
gate: std.atomic.Value(enum(u8) { cancellable, cancelled, publishing }) = .init(.cancellable),
code: @import("protocol.zig").Bounded(64) = .{},
/// A pending publication wakes one UI frame, even after Connecting drew.
/// Guarded with code by the task mutex; not another copy of the code.
code_pending: bool = false,
attempt: core.Attempt = .existing,
outcome: ?Outcome = null,
launch_report: ?host_launch.Summary = null,
threadlocal var current: *Self = undefined;

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

pub fn reset(self: *Self) void {
    std.debug.assert(self.task.thread == null);
    self.key.wipe();
    self.key_rejected = false;
    self.code.len = 0;
    self.code_pending = false;
    self.state = .{};
    self.launch_report = null;
}

pub fn cancel(self: *Self) void {
    _ = self.gate.cmpxchgStrong(.cancellable, .cancelled, .acq_rel, .acquire);
}

/// Every accepted attempt is joined before its input storage is released.
pub fn stop(self: *Self) !void {
    var bytes: [host_launch.max_report_bytes + 256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    const ended = self.stopTo(&writer);
    // The terminal is restored before the app calls stop. If stderr takes
    // nothing there is no second output destination; the error still escapes.
    if (writer.buffered().len != 0) _ = @import("stderr.zig").writeReceipt(writer.buffered());
    try ended;
}

fn stopTo(self: *Self, writer: *std.Io.Writer) !void {
    self.cancel();
    defer self.key.wipe();
    try self.settle(.{ .departure = writer });
}

fn cancelled() bool {
    return current.gate.load(.acquire) == .cancelled;
}

fn publish() bool {
    return current.gate.cmpxchgStrong(.cancellable, .publishing, .acq_rel, .acquire) == null;
}

fn display(code: []const u8) !void {
    const self = current;
    const init = self.init.?;
    self.task.mutex.lockUncancelable(init.io);
    defer self.task.mutex.unlock(init.io);
    try self.code.set(code);
    self.code_pending = true;
}

fn work(raw: *anyopaque, _: *ClientTask) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    current = self;
    self.outcome = if (self.runAttempt()) |published|
        .{ .published = published }
    else |err| if (err == error.LoginInterrupted and cancelled()) .cancelled else .{ .failed = err };
}

fn runAttempt(self: *Self) !Published {
    const init = self.init.?;
    switch (self.attempt) {
        .codex => {
            // Explicit fixture only: no credential, token or network operation.
            if (std.mem.eql(u8, init.environ_map.get("RUI_TEST_LOGIN") orelse "", "waiting")) {
                try display("BDL9-KI88H");
                while (!cancelled()) try init.io.sleep(.fromMilliseconds(20), .awake);
                return error.LoginInterrupted;
            }
            try provider_login.codex(init, codex_auth.login, display, cancelled, publish);
        },
        .key, .existing => {
            if (!publish()) return error.LoginInterrupted;
            if (self.attempt == .key) try provider_login.key(init, self.key.slice());
        },
    }
    // These effects have independent outcomes. Retain both even when the UI
    // leaves after publication and never consumes an activation on a tick.
    const defaults: anyerror!void = if (preferences.saveProviderAfterLogin(init.environ_map.get("HOME") orelse "", self.state.selected, false)) |_| {} else |err| err;
    return .{ .defaults = defaults, .activation = self.activate.?(init, self.selectors) };
}

fn begin(self: *Self, ctx: *vxfw.EventContext, attempt: core.Attempt) void {
    if (attempt != .key) self.key.wipe();
    self.attempt = attempt;
    self.code.len = 0;
    self.code_pending = false;
    self.outcome = null;
    self.launch_report = null;
    self.gate.store(.cancellable, .release);
    const init = self.init orelse return; // UI-only rendering has no effects.
    self.task.start(init.io, self, work) catch {
        self.key.wipe();
        self.key_rejected = false;
        _ = self.state.step(.{ .failed = .login });
    };
    ctx.redraw = true;
}

fn advance(self: *Self, ctx: *vxfw.EventContext) !void {
    if (self.task.thread == null) return;
    self.task.mutex.lockUncancelable(self.init.?.io);
    const pending = self.code_pending;
    self.code_pending = false;
    self.task.mutex.unlock(self.init.?.io);
    ctx.redraw = ctx.redraw or pending;
    if (!self.task.completed()) return;
    try self.settle(.{ .screen = ctx });
}

/// One joined outcome, consumed once by the same reporting owner on a tick
/// or on departure. In particular, a successful activation cannot erase a
/// failed default save, and a failed activation cannot hide it either.
fn settle(self: *Self, presentation: Presentation) !void {
    if (self.task.thread == null) return;
    try self.task.join();
    self.key.wipe();
    self.key_rejected = false;
    const outcome = self.outcome.?;
    self.outcome = null;
    switch (outcome) {
        .cancelled => {},
        .failed => |err| try self.reportFailure(presentation, switch (err) {
            error.LoginExpired => .expired,
            error.LoginDenied => .denied,
            else => .login,
        }, err),
        .published => |published| {
            const default_error: ?anyerror = if (published.defaults) |_| null else |err| err;
            var activation = published.activation catch |err| {
                self.launch_report = .{ .failed = host_launch.failureOf(err) };
                try self.reportFailure(presentation, if (default_error != null) .defaults_and_host else .host, default_error orelse err);
                return;
            };
            if (activation.launch) |*launch| {
                if (presentation == .departure) try host_launch.writeDiagnostics(launch, presentation.departure, 0);
                if (launch.outcome == .failed) {
                    self.launch_report = launch.summary();
                    try self.reportFailure(presentation, if (default_error != null) .defaults_and_host else .host, default_error orelse launch.outcome.failed.cause.err);
                    return;
                }
            }
            if (presentation == .departure) {
                if (default_error) |err| try self.reportFailure(presentation, .defaults, err);
                return;
            }
            const ctx = presentation.screen;
            activation.default_failed = default_error != null; // Borrowed report, not another stored outcome.
            _ = self.state.step(.done);
            if (self.on_done) |done| try done(self.userdata.?, ctx, activation);
            ctx.redraw = true;
        },
    }
}

fn reportFailure(self: *Self, presentation: Presentation, failure: core.Failure, err: anyerror) !void {
    switch (presentation) {
        .screen => |ctx| {
            _ = self.state.step(.{ .failed = failure });
            ctx.redraw = true;
        },
        .departure => |writer| {
            try self.writeFailure(writer, failure, false);
            try writer.writeByte('\n');
            return err;
        },
    }
}

fn appendKey(self: *Self, text: []const u8) void {
    if (self.key_rejected or text.len > self.key.bytes.len - self.key.len) {
        self.key_rejected = true;
        self.state.stage = .key_invalid;
        return;
    }
    @memcpy(self.key.bytes[self.key.len..][0..text.len], text);
    self.key.len += text.len;
    self.state.stage = .key_entry;
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (input == .tick) return self.advance(ctx);
    if (input == .paste_start) {
        self.pasting = true;
        return;
    }
    if (input == .paste_end) {
        self.pasting = false;
        if (self.task.thread == null) {
            const length = api_key.trimNewline(self.key.slice()).len;
            std.crypto.secureZero(u8, self.key.bytes[length..self.key.len]);
            self.key.len = length;
        }
        ctx.redraw = true;
        return;
    }
    if (input == .invalid_key and self.task.thread == null and (self.state.stage == .key_entry or self.state.stage == .key_invalid)) {
        self.key_rejected = true;
        self.state.stage = .key_invalid;
        ctx.consumeAndRedraw();
        return;
    }
    if (input != .key_press) return;
    if (self.pasting) {
        if (self.task.thread == null and (self.state.stage == .key_entry or self.state.stage == .key_invalid)) {
            const key = input.key_press;
            if (key.matches(vaxis.Key.enter, .{})) self.appendKey("\n") else if (key.text) |text| self.appendKey(text);
            ctx.consumeAndRedraw();
        }
        return;
    }
    const key = input.key_press;
    if (key.matches('c', .{ .ctrl = true })) {
        ctx.quit = true;
        return;
    }
    var effect: core.Effect = .none;
    if (key.matches(vaxis.Key.escape, .{})) {
        if (self.task.thread != null and self.state.stage == .choice) return;
        // Leave the running publication visible until its definite answer.
        if (self.task.thread != null and self.gate.cmpxchgStrong(.cancellable, .cancelled, .acq_rel, .acquire) == .publishing) return;
        effect = self.state.step(.escape);
        if (self.task.thread == null) {
            self.key.wipe();
            self.key_rejected = false;
        }
    } else if (self.task.thread != null) {
        return;
    } else if (key.matches(vaxis.Key.enter, .{})) {
        if (self.state.stage == .failed and self.launch_report != null and self.launch_report.? == .failed and self.launch_report.?.failed.next() == null) return;
        effect = if (self.state.stage == .key_entry or self.state.stage == .key_invalid)
            self.state.step(.{ .key = !self.key_rejected and api_key.valid(self.key.slice()) })
        else
            self.state.step(.{ .enter = if (self.init != null and self.ready != null) self.ready.?(self.init.?) else .initFill(.missing) });
    } else if (key.matches(vaxis.Key.left, .{})) {
        effect = self.state.step(.left);
    } else if (key.matches(vaxis.Key.right, .{})) {
        effect = self.state.step(.right);
    } else if (self.state.stage == .key_entry or self.state.stage == .key_invalid) {
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.key.len != 0) {
                self.key.len -= 1;
                self.key.bytes[self.key.len] = 0;
            }
            self.key_rejected = false;
            self.state.stage = .key_entry;
        } else if (key.text) |text| self.appendKey(text);
    }
    switch (effect) {
        .codex => self.begin(ctx, .codex),
        .key => self.begin(ctx, .key),
        .existing => self.begin(ctx, .existing),
        .close => if (self.on_close) |close| try close(self.userdata.?, ctx),
        .cancel, .none => {},
    }
    ctx.consumeAndRedraw();
}

fn writeFailure(self: *Self, writer: *std.Io.Writer, failure: core.Failure, retry_hint: bool) !void {
    if (self.launch_report) |report| {
        if (failure == .host or failure == .defaults_and_host)
            return host_launch.writeSignIn(writer, report, failure == .defaults_and_host, retry_hint);
    }
    try writer.writeAll(failureText(failure));
    if (retry_hint) try writer.writeAll(" · enter tries again");
}

fn failureLine(self: *Self, alloc: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(alloc);
    self.writeFailure(&writer.writer, self.state.failure, true) catch return error.OutOfMemory;
    return writer.written();
}

fn failureText(failure: core.Failure) []const u8 {
    return switch (failure) {
        .expired => comptime core.Provider.codex.shown() ++ " sign-in expired",
        .denied => comptime core.Provider.codex.shown() ++ " sign-in denied",
        .login => "Sign-in failed",
        .defaults => "Sign-in saved; couldn't save default",
        .host => "Sign-in saved; Host didn't start",
        .defaults_and_host => "Sign-in saved; default not saved; Host didn't start",
    };
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const size = ctx.max.size();
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    @memset(surface.buffer, .{ .style = self.style });
    if (size.width == 0 or size.height == 0) return surface;
    const header = try ctx.arena.create(vxfw.Text);
    const list_visible = if (self.list_visible) |visible| visible(self.userdata.?) else false;
    header.* = .{ .text = if (list_visible) "" else " rui", .style = self.style };
    const row: u16 = size.height -| 4;
    const children = try ctx.arena.alloc(vxfw.SubSurface, 3);
    const one = ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 });
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try header.widget().draw(one) };
    if (size.height >= 4) {
        for (0..size.width) |col| {
            surface.writeCell(@intCast(col), row, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = self.quiet });
            surface.writeCell(@intCast(col), row + 2, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = self.quiet });
        }
    }
    var code: @TypeOf(self.code) = .{};
    if (self.task.thread != null) {
        self.task.mutex.lockUncancelable(self.init.?.io);
        code = self.code;
        self.task.mutex.unlock(self.init.?.io);
    } else code = self.code;
    const line: []const vaxis.Cell.Segment = switch (self.state.stage) {
        .choice => try ctx.arena.dupe(vaxis.Cell.Segment, &choice_row.segments(.{ core.Provider.codex.signIn(), core.Provider.openai.signIn() }, .{ if (self.state.selected != .openai) .selected else .plain, if (self.state.selected == .openai) .selected else .plain }, self.style, .{}, true)),
        .codex_waiting => if (code.len == 0) &.{.{ .text = "  Connecting to ChatGPT", .style = self.style }} else line: {
            const segments = try ctx.arena.alloc(vaxis.Cell.Segment, 3);
            segments[0] = .{ .text = "  ", .style = self.style };
            segments[1] = ConversationViewport.linkedSegment("auth.openai.com/codex/device", self.style, "https://auth.openai.com/codex/device");
            segments[2] = .{ .text = try std.fmt.allocPrint(ctx.arena, " · {s}", .{code.slice()}), .style = self.style };
            break :line segments;
        },
        .key_entry => line: {
            const masked = try ctx.arena.alloc(u8, self.key.len * "•".len);
            for (0..self.key.len) |i| @memcpy(masked[i * 3 ..][0..3], "•");
            break :line try ctx.arena.dupe(vaxis.Cell.Segment, &.{.{ .text = if (self.key.len == 0) "  API key" else try std.fmt.allocPrint(ctx.arena, "  {s}", .{masked}), .style = self.style }});
        },
        .key_invalid => &.{.{ .text = "  Invalid API key · edit and enter", .style = self.style }},
        .saving => &.{.{ .text = "  Saving sign-in", .style = self.style }},
        .done => &.{.{ .text = "", .style = self.style }},
        .failed => try ctx.arena.dupe(vaxis.Cell.Segment, &.{.{ .text = try self.failureLine(ctx.arena), .style = self.style }}),
    };
    const rich = try ctx.arena.create(vxfw.RichText);
    rich.* = .{ .text = line, .softwrap = false, .width_basis = .parent };
    children[1] = .{ .origin = .{ .row = @intCast(@min(row + 1, size.height - 1)), .col = 0 }, .surface = try rich.widget().draw(one) };
    const footer = try ctx.arena.create(Footer);
    footer.* = .{
        .left = if (self.state.stage == .codex_waiting) " Waiting for ChatGPT" else " Sign in",
        .right = if (self.state.stage == .choice) "←→ choose · enter " else "esc back ",
        .style = self.quiet,
    };
    children[2] = .{ .origin = .{ .row = @intCast(size.height - 1), .col = 0 }, .surface = try footer.widget().draw(one) };
    surface.children = children;
    return surface;
}

test "Sign-in row drives keys without leaking secrets and refuses overflow" {
    var page: Self = .{};
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.right } });
    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try std.testing.expectEqual(core.Stage.key_entry, page.state.stage);
    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try std.testing.expectEqual(core.Stage.key_invalid, page.state.stage);
    const secret = "sk-test-secret";
    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 's', .text = secret } });
    const drawn = try page.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 12 }, .cell_size = .{} });
    var masks: usize = 0;
    for (drawn.children[1].surface.buffer) |cell| {
        try std.testing.expect(std.mem.indexOf(u8, secret, cell.char.grapheme) == null or std.mem.eql(u8, cell.char.grapheme, " "));
        if (std.mem.eql(u8, cell.char.grapheme, "•")) masks += 1;
    }
    try std.testing.expectEqual(secret.len, masks);
    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'x', .text = &@as([api_key.max_key_bytes]u8, @splat('x')) } });
    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try std.testing.expectEqual(core.Stage.key_invalid, page.state.stage);
    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });
    try std.testing.expectEqual(core.Stage.choice, page.state.stage);
    try std.testing.expectEqual(@as(usize, 0), page.key.len);
    for (page.key.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expect(!page.key_rejected);
    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 's', .text = secret } });
    try page.widget().handleEvent(&ctx, .invalid_key);
    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try std.testing.expectEqual(core.Stage.key_invalid, page.state.stage);
    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });
}

test "Sign-in paste stays masked and its newline cannot submit or choose" {
    var page: Self = .{};
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const Events = @import("testing/app_events.zig").Events;
    var choose: Events = .init("\x1b[200~\r\x1b[201~");
    while (choose.next()) |input| try page.widget().handleEvent(&ctx, input);
    try std.testing.expectEqual(core.Stage.choice, page.state.stage);
    var input: Events = .init("\x1b[C\r\x1b[200~sk-pasted\r\x1b[201~");
    while (input.next()) |event_input| try page.widget().handleEvent(&ctx, event_input);
    try std.testing.expectEqual(core.Stage.key_entry, page.state.stage);
    try std.testing.expectEqualStrings("sk-pasted", page.key.slice());
    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try std.testing.expectEqual(core.Stage.saving, page.state.stage);
}

test "Sign-in worker reports installation default activation and cancellation outcomes" {
    const poll = @import("test_poll");
    const Fixture = struct {
        done: bool = false,
        default_failed: bool = false,
        launch: ?host_launch.Result = null,
        fn activate(init: std.process.Init, _: selection.Intent) !Activation {
            if (init.environ_map.get("FAIL_HOST") != null) return error.HostReadinessUnconfirmed;
            var answer: Activation = .{ .binding = .{}, .store = .{} };
            try answer.binding.provider.set("openai");
            try answer.binding.model.set(@import("product_defaults.zig").recommended_model);
            try answer.store.set(init.environ_map.get("HOME").?);
            return answer;
        }
        fn complete(raw: *anyopaque, _: *vxfw.EventContext, answer: Activation) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.done = true;
            self.default_failed = answer.default_failed;
        }
        fn completed(page: *Self) bool {
            return page.task.completed();
        }
        fn codeReady(page: *Self) bool {
            page.task.mutex.lockUncancelable(page.init.?.io);
            defer page.task.mutex.unlock(page.init.?.io);
            return page.code.len != 0;
        }
    };
    const Case = enum { success, key_failure, default_failure, host_failure, both_failure, cancel };
    for (std.enums.values(Case)) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var home_bytes: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = home_bytes[0..try tmp.dir.realPath(std.testing.io, &home_bytes)];
        var env: std.process.Environ.Map = .init(std.testing.allocator);
        defer env.deinit();
        try env.put("HOME", home);
        var missing_bytes: [std.Io.Dir.max_path_bytes]u8 = undefined;
        if (case == .key_failure) try env.put(api_key.path_variable, try std.fmt.bufPrint(&missing_bytes, "{s}/absent/key", .{home}));
        if (case == .host_failure or case == .both_failure) try env.put("FAIL_HOST", "1");
        if (case == .cancel) try env.put("RUI_TEST_LOGIN", "waiting");
        if (case == .default_failure or case == .both_failure) {
            var config = try tmp.dir.createDirPathOpen(std.testing.io, ".config/rui", .{ .permissions = .fromMode(0o700) });
            defer config.close(std.testing.io);
            var file = try config.createFile(std.testing.io, "preferences", .{ .permissions = .fromMode(0o600) });
            defer file.close(std.testing.io);
            try file.writeStreamingAll(std.testing.io, "version=9\n");
        }
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const argv = [_][*:0]const u8{"rui"};
        const init: std.process.Init = .{ .minimal = .{ .args = .{ .vector = &argv }, .environ = .empty }, .arena = &arena, .gpa = std.testing.allocator, .io = std.testing.io, .environ_map = &env, .preopens = .empty };
        var fixture: Fixture = .{};
        var page: Self = .{ .init = init, .activate = Fixture.activate, .userdata = &fixture, .on_done = Fixture.complete };
        defer page.stop() catch @panic("sign-in attempt escaped its test");
        page.state.selected = if (case == .cancel) .codex else .openai;
        page.state.stage = if (case == .cancel) .codex_waiting else .saving;
        const secret = "sk-worker-test";
        @memcpy(page.key.bytes[0..secret.len], secret);
        page.key.len = secret.len;
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        page.begin(&ctx, if (case == .cancel) .codex else .key);
        if (case == .cancel) {
            try poll.waitUntil(init.io, poll.after(init.io, .fromSeconds(5)), &page, Fixture.codeReady);
            try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });
        }
        try poll.waitUntil(init.io, poll.after(init.io, .fromSeconds(5)), &page, Fixture.completed);
        try page.widget().handleEvent(&ctx, .tick);
        try std.testing.expect(page.task.thread == null);
        try std.testing.expectEqual(@as(usize, 0), page.key.len);
        switch (case) {
            .success, .default_failure => {
                try std.testing.expect(fixture.done);
                try std.testing.expectEqual(case == .default_failure, fixture.default_failed);
                try std.testing.expectEqual(core.Stage.done, page.state.stage);
            },
            .key_failure, .host_failure, .both_failure => {
                try std.testing.expect(!fixture.done);
                try std.testing.expectEqual(core.Stage.failed, page.state.stage);
                try std.testing.expectEqual(if (case == .both_failure) core.Failure.defaults_and_host else if (case == .host_failure) core.Failure.host else core.Failure.login, page.state.failure);
            },
            .cancel => {
                try std.testing.expect(!fixture.done);
                try std.testing.expectEqual(core.Stage.choice, page.state.stage);
            },
        }
        if (case != .key_failure and case != .cancel) {
            var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            var key: api_key.Key = .{};
            defer key.wipe();
            try std.testing.expect(try api_key.read(try api_key.path(&env, &path_buffer), &key) != null);
            try std.testing.expectEqualStrings(secret, key.slice());
        }
    }
}

test "Sign-in choices use approval background selection with and without colour" {
    for ([_]bool{ false, true }) |colour| {
        for ([_]core.Provider{ .codex, .openai }) |provider| {
            var page: Self = .{};
            page.state.selected = provider;
            if (colour) page.style = .{ .fg = .{ .rgb = .{ 200, 210, 220 } }, .bg = .{ .rgb = .{ 20, 30, 40 } } };
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const surface = try page.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 12 }, .cell_size = .{} });
            var text = std.Io.Writer.Allocating.init(arena.allocator());
            for (surface.children[1].surface.buffer, 0..) |cell, column| {
                try text.writer.writeAll(cell.char.grapheme);
                // Each label is selected with its mark or padding, as the provider facts name it.
                const first = core.Provider.codex.signIn().len;
                const second = core.Provider.openai.signIn().len;
                const selected = if (column >= 2 and column <= first + 3) provider == .codex else if (column >= first + 6 and column <= first + second + 7) provider == .openai else false;
                try std.testing.expectEqual(selected, cell.style.reverse);
            }
            try std.testing.expectEqualStrings(" › Device code    API key", std.mem.trimEnd(u8, text.written(), " "));
        }
    }
}

test "Sign-in departure settles cancellation and every published default and activation outcome once" {
    const poll = @import("test_poll");
    const Fixture = struct {
        fn activate(init: std.process.Init, _: selection.Intent) !Activation {
            if (init.environ_map.get("FAIL_HOST") != null) return error.HostReadinessUnconfirmed;
            var answer: Activation = .{ .binding = .{}, .store = .{} };
            try answer.binding.provider.set("openai");
            try answer.binding.model.set(@import("product_defaults.zig").recommended_model);
            try answer.store.set(init.environ_map.get("HOME").?);
            return answer;
        }
        fn completed(page: *Self) bool {
            return page.task.completed();
        }
        fn codeReady(page: *Self) bool {
            page.task.mutex.lockUncancelable(page.init.?.io);
            defer page.task.mutex.unlock(page.init.?.io);
            return page.code.len != 0;
        }
    };
    for ([_]bool{ false, true }) |cancel_before_publication| {
        for ([_]bool{ false, true }) |default_failed| {
            for ([_]bool{ false, true }) |host_failed| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var home_bytes: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const home = home_bytes[0..try tmp.dir.realPath(std.testing.io, &home_bytes)];
                var env: std.process.Environ.Map = .init(std.testing.allocator);
                defer env.deinit();
                try env.put("HOME", home);
                if (cancel_before_publication) try env.put("RUI_TEST_LOGIN", "waiting");
                if (host_failed) try env.put("FAIL_HOST", "1");
                if (default_failed) {
                    var config = try tmp.dir.createDirPathOpen(std.testing.io, ".config/rui", .{ .permissions = .fromMode(0o700) });
                    defer config.close(std.testing.io);
                    var file = try config.createFile(std.testing.io, "preferences", .{ .permissions = .fromMode(0o600) });
                    defer file.close(std.testing.io);
                    try file.writeStreamingAll(std.testing.io, "version=9\n");
                }
                var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer arena.deinit();
                const argv = [_][*:0]const u8{"rui"};
                const init: std.process.Init = .{ .minimal = .{ .args = .{ .vector = &argv }, .environ = .empty }, .arena = &arena, .gpa = std.testing.allocator, .io = std.testing.io, .environ_map = &env, .preopens = .empty };
                var page: Self = .{ .init = init, .activate = Fixture.activate };
                defer page.stop() catch @panic("sign-in escaped departure test");
                page.state.selected = if (cancel_before_publication) .codex else .openai;
                page.state.stage = if (cancel_before_publication) .codex_waiting else .saving;
                const key = "sk-departure-secret";
                @memcpy(page.key.bytes[0..key.len], key);
                page.key.len = key.len;
                var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
                page.begin(&ctx, if (cancel_before_publication) .codex else .key);
                if (cancel_before_publication) {
                    try poll.waitUntil(init.io, poll.after(init.io, .fromSeconds(5)), &page, Fixture.codeReady);
                } else {
                    try poll.waitUntil(init.io, poll.after(init.io, .fromSeconds(5)), &page, Fixture.completed);
                    try std.testing.expectEqual(core.Stage.saving, page.state.stage);
                    try std.testing.expect(page.outcome != null); // No advance consumed it.
                }
                var report: std.Io.Writer.Allocating = .init(arena.allocator());
                const ended = page.stopTo(&report.writer);
                if (cancel_before_publication) {
                    try ended;
                    try std.testing.expectEqualStrings("", report.written());
                    try std.testing.expectEqual(.cancelled, page.gate.load(.acquire));
                    if (default_failed) {
                        try std.testing.expectError(error.UnsupportedPreferencesVersion, preferences.load(home));
                    } else {
                        try std.testing.expectError(error.FileNotFound, tmp.dir.access(init.io, ".config/rui/preferences", .{}));
                    }
                } else {
                    try std.testing.expectEqual(.publishing, page.gate.load(.acquire));
                    if (default_failed) try std.testing.expectError(error.UnsupportedPreferencesVersion, ended) else if (host_failed) try std.testing.expectError(error.HostReadinessUnconfirmed, ended) else try ended;
                    try std.testing.expectEqual(default_failed, std.mem.indexOf(u8, report.written(), if (host_failed) "default not saved" else "couldn't save default") != null);
                    try std.testing.expectEqual(host_failed, std.mem.indexOf(u8, report.written(), "Host start timed out") != null);
                    if (!default_failed) try std.testing.expectEqualStrings("openai", (try preferences.load(home)).provider.slice());
                }
                var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                var saved: api_key.Key = .{};
                defer saved.wipe();
                const installed = try api_key.read(try api_key.path(&env, &path_buffer), &saved);
                try std.testing.expectEqual(!cancel_before_publication, installed != null);
                if (installed != null) try std.testing.expectEqualStrings(key, saved.slice());
                try std.testing.expect(page.task.thread == null and page.outcome == null);
                try std.testing.expectEqual(@as(usize, 0), page.key.len);
                const reported = report.written().len;
                try page.stopTo(&report.writer);
                try std.testing.expectEqual(reported, report.written().len);
            }
        }
    }
}

test "Sign-in launch reporting settles structured outcomes on screen and departure with independent defaults" {
    const Case = enum { refusal, timeout, warning, unserved, incompatible };
    const Fixture = struct {
        const refusal = "child explains its refusal\n[store_format_unsupported]\n";
        warned: bool = false,
        default_failed: bool = false,
        fn activate(init: std.process.Init, _: selection.Intent) !Activation {
            const case = std.meta.stringToEnum(Case, init.environ_map.get("CASE").?).?;
            var answer: Activation = .{ .binding = .{}, .store = .{} };
            try answer.binding.provider.set("openai");
            try answer.binding.model.set(@import("product_defaults.zig").recommended_model);
            try answer.store.set(init.environ_map.get("HOME").?);
            answer.launch = switch (case) {
                .refusal => .failed(.store_format, error.HostStartupFailed),
                .timeout => .failed(.readiness_timeout, error.HostReadinessUnconfirmed),
                .unserved => .failed(.provider_unserved, error.HostModelUnavailable),
                .incompatible => .failed(.incompatible, error.IncompatibleHost),
                .warning => .{ .outcome = .{ .ready = .{ .facts = .{ .store = answer.store, .instance = @splat(1), .active_capacity = 4, .started_at = 1, .custody_occupied = 0, .paused = false, .capabilities = .{ .bash = true, .providers = .{ .codex = .chatgpt_device, .openai = .unserved, .chatgpt = .unserved } } } } }, .warning = .invalid_openai_base_url },
            };
            if (case == .refusal) {
                answer.launch.?.startup_len = refusal.len;
                @memcpy(answer.launch.?.startup_bytes[0..refusal.len], refusal);
                answer.launch.?.outcome.failed.store = answer.store;
            }
            return answer;
        }
        fn complete(raw: *anyopaque, _: *vxfw.EventContext, answer: Activation) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.warned = answer.launch.?.warning == .invalid_openai_base_url;
            self.default_failed = answer.default_failed;
        }
        fn completed(page: *Self) bool {
            return page.task.completed();
        }
    };
    for (std.enums.values(Case)) |case| for ([_]bool{ false, true }) |leave| for ([_]bool{ false, true }) |default_failed| {
        errdefer std.debug.print("launch={s} departure={} default_failed={}\n", .{ @tagName(case), leave, default_failed });
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var home_bytes: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = home_bytes[0..try tmp.dir.realPath(std.testing.io, &home_bytes)];
        var env: std.process.Environ.Map = .init(std.testing.allocator);
        defer env.deinit();
        try env.put("HOME", home);
        try env.put("CASE", @tagName(case));
        if (default_failed) {
            var config = try tmp.dir.createDirPathOpen(std.testing.io, ".config/rui", .{ .permissions = .fromMode(0o700) });
            defer config.close(std.testing.io);
            var file = try config.createFile(std.testing.io, "preferences", .{ .permissions = .fromMode(0o600) });
            defer file.close(std.testing.io);
            try file.writeStreamingAll(std.testing.io, "version=9\n");
        }
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const argv = [_][*:0]const u8{"rui"};
        const init: std.process.Init = .{ .minimal = .{ .args = .{ .vector = &argv }, .environ = .empty }, .arena = &arena, .gpa = std.testing.allocator, .io = std.testing.io, .environ_map = &env, .preopens = .empty };
        var fixture: Fixture = .{};
        var page: Self = .{ .init = init, .activate = Fixture.activate, .userdata = &fixture, .on_done = Fixture.complete };
        defer page.stop() catch @panic("reporting outcome escaped settlement");
        page.state = .{ .selected = .openai, .stage = .saving };
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        page.begin(&ctx, .existing);
        const poll = @import("test_poll");
        try poll.waitUntil(init.io, poll.after(init.io, .fromSeconds(5)), &page, Fixture.completed);
        var report: std.Io.Writer.Allocating = .init(arena.allocator());
        if (leave) {
            const ended = page.stopTo(&report.writer);
            const expected: ?anyerror = if (default_failed) error.UnsupportedPreferencesVersion else switch (case) {
                .refusal => error.HostStartupFailed,
                .timeout => error.HostReadinessUnconfirmed,
                .unserved => error.HostModelUnavailable,
                .incompatible => error.IncompatibleHost,
                .warning => null,
            };
            if (expected) |err| try std.testing.expectError(err, ended) else try ended;
            const text = report.written();
            switch (case) {
                .refusal => {
                    try std.testing.expectEqual(true, std.mem.indexOf(u8, text, Fixture.refusal) != null);
                    try std.testing.expect(std.mem.indexOf(u8, text, home) != null);
                },
                .timeout => try std.testing.expect(std.mem.indexOf(u8, text, "do not kill or reclaim an uncertain owner") != null),
                .warning => try std.testing.expect(std.mem.indexOf(u8, text, host_launch.invalid_base_url) != null),
                .unserved => try std.testing.expect(std.mem.indexOf(u8, text, "does not serve the selected provider") != null),
                .incompatible => try std.testing.expect(std.mem.indexOf(u8, text, "does not speak this rui's protocol") != null),
            }
            try std.testing.expectEqual(default_failed, std.mem.indexOf(u8, text, if (case == .warning) "couldn't save default" else "default not saved") != null);
        } else {
            try page.advance(&ctx);
            if (case == .warning) {
                try std.testing.expectEqual(core.Stage.done, page.state.stage);
                try std.testing.expect(fixture.warned);
                try std.testing.expectEqual(default_failed, fixture.default_failed);
            } else {
                const line = try page.failureLine(arena.allocator());
                try std.testing.expectEqual(core.Stage.failed, page.state.stage);
                try std.testing.expect(std.mem.indexOfAny(u8, line, "\r\n\x1b") == null);
                try std.testing.expect(std.mem.indexOf(u8, line, Fixture.refusal) == null);
                try std.testing.expectEqual(case == .timeout, std.mem.indexOf(u8, line, "enter tries again") != null);
                try std.testing.expectEqual(default_failed, std.mem.indexOf(u8, line, "default not saved") != null);
                if (case == .refusal or case == .unserved or case == .incompatible) {
                    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
                    try std.testing.expect(page.task.thread == null);
                    try std.testing.expectEqual(core.Stage.failed, page.state.stage);
                }
            }
        }
        try std.testing.expect(page.task.thread == null and page.outcome == null);
        const reported = report.written().len;
        try page.stopTo(&report.writer);
        try std.testing.expectEqual(reported, report.written().len);
    };
}

test "Sign-in device publication after Connecting wakes exactly one frame while the worker waits" {
    const Gate = struct {
        page: *Self,
        publish_code: std.Io.Event = .unset,
        published: std.Io.Event = .unset,
        finish: std.Io.Event = .unset,
        fn run(raw: *anyopaque, task: *ClientTask) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            current = self.page;
            self.publish_code.waitUncancelable(task.io);
            try display("BDL9-KI88H");
            self.published.set(task.io);
            self.finish.waitUncancelable(task.io);
            self.page.outcome = .cancelled;
        }
    };
    const io = std.testing.io;
    var init: std.process.Init = undefined;
    init.io = io;
    var page: Self = .{ .init = init, .state = .{ .stage = .codex_waiting } };
    var gate: Gate = .{ .page = &page };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try page.task.start(io, &gate, Gate.run);
    defer {
        gate.publish_code.set(io);
        gate.finish.set(io);
        page.stop() catch @panic("device publication escaped settlement");
    }
    var ctx: vxfw.EventContext = .{ .io = io, .alloc = arena.allocator(), .cmds = .empty, .redraw = false };
    const draw_context: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 12 }, .cell_size = .{} };
    // Guarantee the initial frame and tick precede publication, rather than
    // letting worker scheduling decide which frame the test happened to see.
    const connecting = try page.widget().draw(draw_context);
    const initial: *vxfw.RichText = @ptrCast(@alignCast(connecting.children[1].surface.widget.userdata));
    try std.testing.expectEqualStrings("  Connecting to ChatGPT", initial.text[0].text);
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqual(false, ctx.redraw);
    gate.publish_code.set(io);
    gate.published.waitUncancelable(io);
    try std.testing.expect(!page.task.completed());
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqual(true, ctx.redraw);
    const shown = try page.widget().draw(draw_context);
    const line: *vxfw.RichText = @ptrCast(@alignCast(shown.children[1].surface.widget.userdata));
    try std.testing.expectEqualStrings("auth.openai.com/codex/device", line.text[1].text);
    try std.testing.expectEqualStrings(" · BDL9-KI88H", line.text[2].text);
    try std.testing.expectEqualStrings("https://auth.openai.com/codex/device", line.text[1].link.uri);
    ctx.redraw = false;
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqual(false, ctx.redraw);
}
