//! One App owns terminal custody for the overview and every Session it opens.
const std = @import("std");
const vaxis = @import("vaxis");
const alert = @import("attention.zig");
const session_id = @import("session_id.zig");
const Self = @This();

app: vaxis.vxfw.App = undefined,
output: [4096]u8 = undefined,
previous: [Signals.handled.len]std.posix.Sigaction = undefined,
attention: Attention = undefined,

pub fn init(self: *Self, io: std.Io, environ: *std.process.Environ.Map) !void {
    self.* = .{};
    Signals.stopped.store(false, .release);
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = Signals.handle },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    inline for (Signals.handled, 0..) |signal, index| std.posix.sigaction(signal, &action, &self.previous[index]);
    errdefer self.restoreSignals(.all);
    self.app = try .init(io, std.heap.page_allocator, environ, &self.output);
    self.attention = .of(&self.app.vx, self.app.tty.writer(), environ);
}

pub fn deinit(self: *Self) void {
    // A partial status write may have reached the terminal. Clear Rui's
    // record tree before restoring modes, without preventing restoration
    // if the output channel has failed.
    self.attention.clear() catch |err| std.log.err("clearing Rui terminal status: {}", .{err});
    self.app.deinit();
    self.restoreSignals(.keep_hangup);
}

/// Exit continues past App. When the terminal closes, its shell forwards a
/// hangup to Rui, which may arrive only after App saw the end of input and
/// released the terminal; Rui's handler then keeps it from ending that exit.
fn restoreSignals(self: *Self, which: enum { all, keep_hangup }) void {
    inline for (Signals.handled, 0..) |signal, index| {
        if (which == .all or signal != std.posix.SIG.HUP) std.posix.sigaction(signal, &self.previous[index], null);
    }
}

pub fn run(self: *Self, root: vaxis.vxfw.Widget) !void {
    try self.app.run(root, .{});
}

/// Guidance after App has released the terminal. The shared nonblocking
/// stderr writer cannot hold exit behind a hung-up or backpressured TTY.
pub fn detached(store: []const u8, opened: ?[]const u8, action: ?u64) void {
    const protocol = @import("protocol.zig");
    const Text = @import("TerminalText.zig");
    var buffer: [4 * (4 * (protocol.max_store_bytes + protocol.max_session_bytes) + 128)]u8 = undefined;
    var notice = std.Io.Writer.fixed(&buffer);
    notice.writeAll("\nDetached. Host work continues.\n") catch unreachable;
    if (opened) |session| {
        notice.writeAll("Resume: rui session resume --store ") catch unreachable;
        Text.writeShellWord(&notice, store) catch unreachable;
        Text.writeShellSession(&notice, session, true) catch unreachable;
        notice.writeByte('\n') catch unreachable;
        if (action) |id| {
            notice.writeAll("Pending Action: inspect the complete proposal before deciding.\n") catch unreachable;
            for ([_][]const u8{ "inspect", "allow", "deny" }) |command| {
                notice.print("rui action {s} --store ", .{command}) catch unreachable;
                Text.writeShellWord(&notice, store) catch unreachable;
                Text.writeShellSession(&notice, session, false) catch unreachable;
                notice.print(" --action {d}\n", .{id}) catch unreachable;
            }
        }
    } else {
        notice.writeAll("Overview: rui --store ") catch unreachable;
        Text.writeShellWord(&notice, store) catch unreachable;
        notice.writeByte('\n') catch unreachable;
    }
    _ = @import("stderr.zig").write(notice.buffered());
}

/// The terminal's attention channel beside App's frames: each Session's
/// program-status record where the terminal takes them, and otherwise a
/// notification in the signal its environment understands.
pub const Attention = struct {
    vx: *vaxis.Vaxis,
    out: *std.Io.Writer,
    signal: alert.Signal,
    statuses_shown: bool = false,

    pub fn of(vx: *vaxis.Vaxis, out: *std.Io.Writer, environ: *const std.process.Environ.Map) Attention {
        const inside = environ.get("TMUX") != null or environ.get("STY") != null;
        return .{ .vx = vx, .out = out, .signal = alert.signal(environ.get("TERM") orelse "", environ.get("TERM_PROGRAM") orelse "", inside) };
    }

    /// True once the record went out. The overview then marks its value as
    /// delivered, without a second frame ledger.
    pub fn report(self: *Attention, session: *const [session_id.bytes]u8, name: []const u8, status: ?alert.Status) !bool {
        if (!self.vx.caps.program_status) return false;
        var id: ["rui/".len + session_id.bytes]u8 = undefined;
        @memcpy(id[0..4], "rui/");
        @memcpy(id[4..], session);
        if (status) |value| {
            self.statuses_shown = true;
            const title = @import("session_line.zig").cut(alert.max_name_bytes, name);
            try self.vx.reportProgramStatus(self.out, .{
                .id = &id,
                .app = "rui",
                .state = switch (value) {
                    .idle => .idle,
                    .working => .working,
                    .done => .done,
                    .blocked => .blocked,
                    .failed => .@"error",
                },
                .kind = if (value == .blocked) .permission else null,
                .msg = title.slice(),
            });
        } else try self.vx.clearProgramStatus(self.out, &id);
        try self.out.flush();
        return true;
    }

    pub fn clear(self: *Attention) !void {
        if (!self.statuses_shown) return;
        try self.vx.clearProgramStatus(self.out, "rui");
        self.statuses_shown = false;
    }

    /// A terminal that takes records shows the news from them instead, so
    /// nothing comes twice.
    pub fn notify(self: *Attention, name: []const u8, kind: alert.Kind, more: usize) !void {
        if (self.vx.caps.program_status) return;
        try alert.write(self.out, self.signal, name, kind, more);
        try self.out.flush();
    }
};

/// The root samples this on its recurring tick and requests ctx.quit. The
/// handler never writes to the TTY or runs disposal in signal context.
pub fn interrupted() bool {
    return Signals.stopped.load(.acquire);
}

const Signals = struct {
    const handled = .{ std.posix.SIG.INT, std.posix.SIG.TERM, std.posix.SIG.HUP };
    var stopped: std.atomic.Value(bool) = .init(false);

    fn handle(_: std.posix.SIG) callconv(.c) void {
        stopped.store(true, .release);
    }
};

/// Test-only accounting of page-rounded backing storage, not process RSS.
/// Forward every operation so measuring does not change allocator behavior.
const TestMemory = struct {
    used: usize = 0,
    peak: usize = 0,

    fn allocator(self: *TestMemory) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn charge(length: usize) usize {
        return std.mem.alignForward(usize, length, std.heap.pageSize());
    }

    fn account(self: *TestMemory, old: usize, new: usize) void {
        self.used = self.used - charge(old) + charge(new);
        self.peak = @max(self.peak, self.used);
    }

    fn alloc(raw: *anyopaque, length: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *TestMemory = @ptrCast(@alignCast(raw));
        const bytes = std.heap.page_allocator.rawAlloc(length, alignment, address) orelse return null;
        self.account(0, length);
        return bytes;
    }

    fn resize(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, new: usize, address: usize) bool {
        const self: *TestMemory = @ptrCast(@alignCast(raw));
        if (!std.heap.page_allocator.rawResize(bytes, alignment, new, address)) return false;
        self.account(bytes.len, new);
        return true;
    }

    fn remap(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, new: usize, address: usize) ?[*]u8 {
        const self: *TestMemory = @ptrCast(@alignCast(raw));
        const result = std.heap.page_allocator.rawRemap(bytes, alignment, new, address) orelse return null;
        self.account(bytes.len, new);
        return result;
    }

    fn free(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *TestMemory = @ptrCast(@alignCast(raw));
        std.heap.page_allocator.rawFree(bytes, alignment, address);
        self.account(bytes.len, 0);
    }
};

test "App memory holds 49152-cell grids and a rendered Unicode widget surface" {
    var memory: TestMemory = .{};
    const allocator = memory.allocator();
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    var bytes: [4096]u8 = undefined;
    var output: std.Io.Writer.Discarding = .init(&bytes);
    {
        var vx = try vaxis.init(std.testing.io, allocator, &environment, .{});
        defer vx.deinit(allocator, &output.writer);
        const text: vaxis.vxfw.Text = .{ .text = "" };
        for ([_]vaxis.vxfw.Size{ .{ .width = 2048, .height = 24 }, .{ .width = 256, .height = 192 } }) |size| {
            try vx.resize(allocator, &output.writer, .{ .cols = size.width, .rows = size.height, .x_pixel = 0, .y_pixel = 0 });
            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            const surface = try vaxis.vxfw.Surface.init(arena.allocator(), text.widget(), size);
            @memset(surface.buffer, .{ .char = .{ .grapheme = "e\u{0301}", .width = 1 } });
            surface.render(vx.window(), text.widget());
            try vx.render(&output.writer);
            std.debug.print("App {d}x{d} Unicode frame: live={d}, peak={d} page-rounded bytes\n", .{ size.width, size.height, memory.used, memory.peak });
            try std.testing.expect(memory.peak <= 32 * 1024 * 1024);
        }
    }
    try std.testing.expect(output.fullCount() > 49_152);
    try std.testing.expectEqual(@as(usize, 0), memory.used);
}

test "App memory reuses replacement text and links across rendered frames" {
    var memory: TestMemory = .{};
    const allocator = memory.allocator();
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    var bytes: [4096]u8 = undefined;
    var output: std.Io.Writer.Discarding = .init(&bytes);
    {
        var vx = try vaxis.init(std.testing.io, allocator, &environment, .{});
        defer vx.deinit(allocator, &output.writer);
        try vx.resize(allocator, &output.writer, .{ .cols = 256, .rows = 192, .x_pixel = 0, .y_pixel = 0 });
        const text: vaxis.vxfw.Text = .{ .text = "" };
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const surface = try vaxis.vxfw.Surface.init(arena.allocator(), text.widget(), .{ .width = 256, .height = 192 });
        const values = [_]vaxis.Cell{
            .{ .char = .{ .grapheme = "e\u{0301}", .width = 1 }, .link = .{ .uri = "https://x", .params = "id=a" } },
            .{ .char = .{ .grapheme = "A", .width = 1 } },
            .{ .char = .{ .grapheme = "o\u{0301}\u{0308}", .width = 1 }, .link = .{ .uri = "https://xy", .params = "id=bc" } },
        };
        var settled_peak: usize = 0;
        for (0..4) |cycle| {
            for (values) |value| {
                @memset(surface.buffer, value);
                surface.render(vx.window(), text.widget());
                try vx.render(&output.writer);
                for (0..192) |row| for (0..256) |col| {
                    const actual = vx.screen_last.readCell(@intCast(col), @intCast(row)).?;
                    try std.testing.expectEqualStrings(value.char.grapheme, actual.char.grapheme);
                    try std.testing.expectEqualStrings(value.link.uri, actual.link.uri);
                    try std.testing.expectEqualStrings(value.link.params, actual.link.params);
                };
            }
            if (cycle == 0) settled_peak = memory.peak else try std.testing.expectEqual(settled_peak, memory.peak);
        }
        try std.testing.expect(memory.peak <= 32 * 1024 * 1024);
    }
    try std.testing.expectEqual(@as(usize, 0), memory.used);
}
