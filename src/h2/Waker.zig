//! Ends a `Client.wait` early from another thread: an eventfd on Linux, a
//! nonblocking pipe elsewhere. Writes coalesce, and `wait` drains it.
const std = @import("std");
const builtin = @import("builtin");
const Waker = @This();

/// Polled for readability.
read_fd: std.posix.fd_t,
/// The same descriptor as `read_fd` for an eventfd.
write_fd: std.posix.fd_t,

pub fn init() error{SystemResources}!Waker {
    if (builtin.os.tag == .linux) {
        const fd = std.c.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        if (fd < 0) return error.SystemResources;
        return .{ .read_fd = fd, .write_fd = fd };
    }
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.SystemResources;
    errdefer for (fds) |fd| {
        _ = std.c.close(fd);
    };
    for (fds) |fd| {
        if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) return error.SystemResources;
        const flags = std.c.fcntl(fd, std.c.F.GETFL);
        const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
        if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | nonblock) < 0) return error.SystemResources;
    }
    return .{ .read_fd = fds[0], .write_fd = fds[1] };
}

pub fn deinit(self: *Waker) void {
    _ = std.c.close(self.read_fd);
    if (self.write_fd != self.read_fd) _ = std.c.close(self.write_fd);
    self.* = undefined;
}

/// Any thread. A full pipe or a saturated counter already means "woken".
pub fn wake(self: *Waker) void {
    const one: u64 = 1;
    const bytes = std.mem.asBytes(&one);
    _ = std.c.write(self.write_fd, bytes, if (self.write_fd == self.read_fd) bytes.len else 1);
}

/// Owner thread, after `poll` reported it readable.
pub fn drain(self: *Waker) void {
    var buffer: [64]u8 = undefined;
    while (std.c.read(self.read_fd, &buffer, buffer.len) > 0) {}
}

test "a wake makes the descriptor readable until drained" {
    var waker = try init();
    defer waker.deinit();
    var poll = [_]std.c.pollfd{.{ .fd = waker.read_fd, .events = std.c.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(c_int, 0), std.c.poll(&poll, 1, 0));
    waker.wake();
    waker.wake();
    try std.testing.expectEqual(@as(c_int, 1), std.c.poll(&poll, 1, 0));
    waker.drain();
    try std.testing.expectEqual(@as(c_int, 0), std.c.poll(&poll, 1, 0));
}
