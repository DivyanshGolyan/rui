//! Socket calls whose Linux and Darwin results differ.

const std = @import("std");
const builtin = @import("builtin");

/// Linux raises SIGPIPE on a send to a peer that went away unless the send
/// passes MSG_NOSIGNAL; Darwin turns it off per socket instead (`configure`).
pub const send_flags: c_int = if (builtin.os.tag == .linux) std.c.MSG.NOSIGNAL else 0;

pub const ConnectStatus = enum { connected, refused, pending, failed };

/// A null socket error means the corresponding getsockopt failed.
pub fn connectResult(first: ?c_int, peer: std.posix.E, reread: ?c_int) ConnectStatus {
    const initial = first orelse return .failed;
    if (initial != 0) return .refused;
    return switch (peer) {
        .SUCCESS => .connected,
        .NOTCONN => .pending,
        else => if (reread != null and reread.? != 0) .refused else .failed,
    };
}

/// SO_ERROR is consumed by each read. A reset between the first read and
/// getpeername can produce EINVAL on Darwin (#1106), so read it again.
pub fn connectStatus(fd: std.c.fd_t) ConnectStatus {
    var value: c_int = 0;
    var len: std.c.socklen_t = @sizeOf(c_int);
    if (std.c.getsockopt(fd, std.c.SOL.SOCKET, std.c.SO.ERROR, &value, &len) != 0)
        return connectResult(null, .SUCCESS, null);
    if (value != 0) return connectResult(value, .SUCCESS, null);
    var peer: std.c.sockaddr.in6 = undefined;
    var peer_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in6);
    const result = std.posix.errno(std.c.getpeername(fd, @ptrCast(&peer), &peer_len));
    if (result == .SUCCESS or result == .NOTCONN) return connectResult(value, result, null);
    len = @sizeOf(c_int);
    const reread: ?c_int = if (std.c.getsockopt(fd, std.c.SOL.SOCKET, std.c.SO.ERROR, &value, &len) == 0) value else null;
    return connectResult(0, result, reread);
}

test "connect result classifies socket observations" {
    const cases = .{
        .{ @as(?c_int, null), std.posix.E.SUCCESS, @as(?c_int, null), ConnectStatus.failed },
        .{ @as(?c_int, 111), std.posix.E.SUCCESS, @as(?c_int, null), ConnectStatus.refused },
        .{ @as(?c_int, 0), std.posix.E.SUCCESS, @as(?c_int, null), ConnectStatus.connected },
        .{ @as(?c_int, 0), std.posix.E.NOTCONN, @as(?c_int, null), ConnectStatus.pending },
        // Darwin #1106: a reset arrives after the first SO_ERROR read.
        .{ @as(?c_int, 0), std.posix.E.INVAL, @as(?c_int, 61), ConnectStatus.refused },
        .{ @as(?c_int, 0), std.posix.E.INVAL, @as(?c_int, 0), ConnectStatus.failed },
        .{ @as(?c_int, 0), std.posix.E.INVAL, @as(?c_int, null), ConnectStatus.failed },
    };
    inline for (cases) |case| try std.testing.expectEqual(case[3], connectResult(case[0], case[1], case[2]));
}

/// Close-on-exec, non-blocking, over TCP no Nagle delay, and on Darwin no
/// SIGPIPE when the peer went away.
pub fn configure(fd: std.c.fd_t, tcp: bool) bool {
    if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) return false;
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | nonblock) < 0) return false;
    const one: c_int = 1;
    if (tcp and std.c.setsockopt(fd, std.c.IPPROTO.TCP, std.c.TCP.NODELAY, &one, @sizeOf(c_int)) != 0) return false;
    if (builtin.os.tag.isDarwin()) {
        if (std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, &one, @sizeOf(c_int)) != 0) return false;
    }
    return true;
}

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
