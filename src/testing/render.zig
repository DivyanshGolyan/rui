//! Unit fixture for a screen borrowing the invocation backend.
const std = @import("std");
const Backend = @import("../RenderBackend.zig");
const vaxis = @import("vaxis");
const View = @import("../session_view.zig");

pub fn init(screen: anytype, io: std.Io, env: *std.process.Environ.Map, colour: bool) !void {
    const backend = try std.testing.allocator.create(Backend);
    errdefer std.testing.allocator.destroy(backend);
    backend.* = .{};
    try backend.init(io, env, .{ .depth = if (colour) .indexed else .none });
    screen.init(backend);
}
pub fn deinit(screen: anytype) void {
    screen.backend.deinit();
    std.testing.allocator.destroy(screen.backend);
}
pub fn render(screen: anytype, out: *std.Io.Writer, size: std.posix.winsize, bytes: []const u8, cursor: usize, footer: @TypeOf(screen.*).Footer, live: *const View.Live) !@TypeOf(screen.*).Delivered {
    const reflow = screen.prepareFrame(size) catch |err| {
        screen.backend.poison();
        return err;
    };
    defer screen.backend.end();
    errdefer screen.backend.poison();
    return screen.renderPrepared(out, size, reflow, bytes, cursor, footer, live);
}

pub const Window = struct {
    backend: *Backend,
    width: u16,
    height: u16,
    pub fn readCell(self: Window, col: u16, row: u16) ?vaxis.Cell {
        return self.backend.storage.?.vx.screen_last.readCell(col, row);
    }
};
pub fn window(screen: anytype) Window {
    return .{ .backend = screen.backend, .width = screen.backend.geometry().cols, .height = screen.backend.geometry().rows };
}
