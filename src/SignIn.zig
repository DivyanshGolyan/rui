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
const Self = @This();

pub const Activation = struct {
    binding: selection.Binding,
    store: @import("protocol.zig").Bounded(@import("protocol.zig").max_store_bytes),
    default_failed: bool = false,
};
pub const Activate = *const fn (std.process.Init, selection.Intent) anyerror!Activation;
pub const Ready = *const fn (std.process.Init, @import("protocol.zig").Provider) bool;
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
show_title: bool = true,
pasting: bool = false,
task: ClientTask = .{},
/// Cancellation and publication claim the same gate, as the CLI does. Once
/// publication wins, Escape cannot claim that the saved sign-in was undone.
gate: std.atomic.Value(enum(u8) { cancellable, cancelled, publishing }) = .init(.cancellable),
code: @import("protocol.zig").Bounded(64) = .{},
answer: ?Activation = null,
worker_failure: core.Failure = .login,
threadlocal var current: *Self = undefined;

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

pub fn reset(self: *Self) void {
    std.debug.assert(self.task.thread == null);
    self.key.wipe();
    self.key_rejected = false;
    self.code.len = 0;
    self.state = .{};
}

pub fn cancel(self: *Self) void {
    _ = self.gate.cmpxchgStrong(.cancellable, .cancelled, .acq_rel, .acquire);
}

/// Every accepted attempt is joined before its input storage is released.
pub fn stop(self: *Self) !void {
    self.cancel();
    defer self.key.wipe();
    self.task.join() catch |err| {
        // Cancellation before publication has no effect to report. Every
        // failure after publication is retained at the departure boundary.
        if (err != error.LoginInterrupted or self.gate.load(.acquire) != .cancelled) return err;
    };
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
}

fn work(raw: *anyopaque, _: *ClientTask) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    current = self;
    const init = self.init.?;
    const provider = self.state.selected;
    if (provider == .codex and !(if (self.ready) |ready| ready(init, provider) else false)) {
        // Explicit fixture only: no credential, token or network operation.
        if (std.mem.eql(u8, init.environ_map.get("RUI_TEST_LOGIN") orelse "", "waiting")) {
            try display("BDL9-KI88H");
            while (!cancelled()) try init.io.sleep(.fromMilliseconds(20), .awake);
            return error.LoginInterrupted;
        }
        try provider_login.codex(init, codex_auth.login, display, cancelled, publish);
    } else {
        if (!publish()) return error.LoginInterrupted;
        if (provider == .openai) try provider_login.key(init, self.key.slice());
    }
    self.worker_failure = .defaults;
    const default_failed = if (preferences.saveProviderAfterLogin(init.environ_map.get("HOME") orelse "", provider, false)) |_| false else |_| true;
    // Publication and defaults are independent. Explicit launch selectors can
    // still activate when the future default could not be saved.
    if (!default_failed) self.worker_failure = .host;
    self.answer = try self.activate.?(init, self.selectors);
    self.answer.?.default_failed = default_failed;
}

fn begin(self: *Self, ctx: *vxfw.EventContext) void {
    self.key.len = if (self.state.selected == .openai) self.key.len else 0;
    self.code.len = 0;
    self.answer = null;
    self.worker_failure = .login;
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
    if (self.task.thread == null or !self.task.completed()) return;
    const outcome = self.task.join();
    self.key.wipe();
    self.key_rejected = false;
    outcome catch |err| {
        if (err == error.LoginInterrupted and self.gate.load(.acquire) == .cancelled) return;
        const failure: core.Failure = switch (err) {
            error.LoginExpired => .expired,
            error.LoginDenied => .denied,
            else => self.worker_failure,
        };
        _ = self.state.step(.{ .failed = failure });
        ctx.redraw = true;
        return;
    };
    _ = self.state.step(.done);
    if (self.on_done) |done| done(self.userdata.?, ctx, self.answer.?) catch {
        _ = self.state.step(.{ .failed = .defaults });
    };
    ctx.redraw = true;
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
        effect = if (self.state.stage == .key_entry or self.state.stage == .key_invalid)
            self.state.step(.{ .key = !self.key_rejected and api_key.valid(self.key.slice()) })
        else
            self.state.step(.enter);
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
        .codex, .key => self.begin(ctx),
        .close => if (self.on_close) |close| try close(self.userdata.?, ctx),
        .cancel, .none => {},
    }
    ctx.consumeAndRedraw();
}

fn failureText(failure: core.Failure) []const u8 {
    return switch (failure) {
        .expired => "ChatGPT sign-in expired · enter tries again",
        .denied => "ChatGPT sign-in denied · enter tries again",
        .login => "Sign-in failed · enter tries again",
        .defaults => "Sign-in saved; couldn't save default · enter tries again",
        .host => "Sign-in saved; Host didn't start · enter tries again",
    };
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const size = ctx.max.size();
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    @memset(surface.buffer, .{ .style = self.style });
    if (size.width == 0 or size.height == 0) return surface;
    const header = try ctx.arena.create(vxfw.Text);
    header.* = .{ .text = if (self.show_title) " rui" else "", .style = self.style };
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
        .choice => if (self.state.selected == .codex) &.{.{ .text = "  [ChatGPT]   API key", .style = self.style }} else &.{.{ .text = "  ChatGPT   [API key]", .style = self.style }},
        .codex_waiting => if (code.len == 0) &.{.{ .text = "  Connecting to ChatGPT", .style = self.style }} else line: {
            const segments = try ctx.arena.alloc(vaxis.Cell.Segment, 3);
            // At phone width the label contracts, never the code or link.
            segments[0] = .{ .text = if (size.width < 65) " " else "  Open ", .style = self.style };
            segments[1] = .{ .text = "auth.openai.com/codex/device", .style = self.style, .link = .{ .uri = "https://auth.openai.com/codex/device" } };
            segments[2] = .{ .text = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ if (size.width < 65) " " else " and enter ", code.slice() }), .style = self.style };
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
        .failed => try ctx.arena.dupe(vaxis.Cell.Segment, &.{.{ .text = failureText(self.state.failure), .style = self.style }}),
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
    const Case = enum { success, key_failure, default_failure, host_failure, cancel };
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
        if (case == .host_failure) try env.put("FAIL_HOST", "1");
        if (case == .cancel) try env.put("RUI_TEST_LOGIN", "waiting");
        if (case == .default_failure) {
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
        page.begin(&ctx);
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
            .key_failure, .host_failure => {
                try std.testing.expect(!fixture.done);
                try std.testing.expectEqual(core.Stage.failed, page.state.stage);
                try std.testing.expectEqual(if (case == .host_failure) core.Failure.host else core.Failure.login, page.state.failure);
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
