//! Socket calls whose Linux and Darwin results differ.

const std = @import("std");

pub const Shutdown = enum { done, peer_gone, failed };

/// Darwin's shutdown returns ENOTCONN once the peer has closed, where Linux
/// succeeds; either way the connection is down.
pub fn shutdown(fd: std.c.fd_t, how: c_int) Shutdown {
    if (std.c.shutdown(fd, how) == 0) return .done;
    return if (std.c.errno(-1) == .NOTCONN) .peer_gone else .failed;
}

test "shutdown of an unconnected socket reports the peer gone" {
    // TCP: Linux accepts shutdown of an unconnected Unix stream socket.
    const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    try std.testing.expectEqual(Shutdown.peer_gone, shutdown(fd, std.c.SHUT.RDWR));
    try std.testing.expectEqual(Shutdown.failed, shutdown(-1, std.c.SHUT.RDWR));
}
