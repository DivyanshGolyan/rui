//! A scripted Host for client tests: a private Store lease and socket whose
//! connections a test's `host.answer(fd)` serves one at a time, so client
//! reads run over the real wire against replies the test chose.
const std = @import("std");
const socket_os = @import("os").socket;
const protocol = @import("../protocol.zig");
const platform = @import("../platform.zig");
const host_endpoint = @import("../host_endpoint.zig");

/// Serves `host.answer(fd)` on a fresh private Store socket while `action.run(host, dir, root)` runs.
pub fn withHost(host: anytype, action: anytype) !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var lease = try platform.StoreLease.acquire(io, root);
    defer lease.release();
    try lease.prepareForServing(false);
    const paths = lease.paths;
    var endpoint = try host_endpoint.claim(io, try .init(std.fs.path.dirname(paths.socket.slice()).?));
    defer endpoint.retire() catch @panic("unable to retire fixture endpoint");
    var listener = try endpoint.listen(.{});
    defer listener.deinit(io);
    const Server = Serving(@TypeOf(host));
    var server: Server = .{ .host = host, .listener = &listener };
    const thread = try std.Thread.spawn(.{}, Server.serve, .{&server});
    defer {
        server.stopping.store(true, .release);
        if ((std.Io.net.UnixAddress.init(paths.socket.slice()) catch unreachable).connect(io)) |wake| wake.close(io) else |_| {}
        thread.join();
    }
    try action.run(host, tmp.dir, root);
}

fn Serving(comptime Host: type) type {
    return struct {
        host: Host,
        listener: *std.Io.net.Server,
        stopping: std.atomic.Value(bool) = .init(false),

        fn serve(self: *@This()) void {
            while (true) {
                const peer = self.listener.accept(std.testing.io) catch return;
                defer peer.close(std.testing.io);
                if (self.stopping.load(.acquire)) return;
                if (!socket_os.suppressSigpipe(peer.socket.handle)) return;
                self.host.answer(peer.socket.handle) catch {};
            }
        }
    };
}

pub const Request = struct {
    /// The request head, starting with its request line.
    head: []const u8,
    body: []const u8,

    pub fn is(self: Request, comptime route: []const u8) bool {
        return std.mem.startsWith(u8, self.head, "POST " ++ route ++ " ");
    }
};

/// Reads one whole request into `buffer`; null when the peer closed before sending one.
pub fn readRequest(fd: std.posix.fd_t, buffer: *[8192]u8) !?Request {
    var used: usize = 0;
    const body_start = while (true) {
        const count = try std.posix.read(fd, buffer[used..]);
        if (count == 0) return null;
        used += count;
        if (std.mem.indexOf(u8, buffer[0..used], "\r\n\r\n")) |at| break at + 4;
    };
    const marker = "Content-Length: ";
    const length_at = std.mem.indexOf(u8, buffer[0..body_start], marker).? + marker.len;
    const length = try std.fmt.parseInt(usize, buffer[length_at..std.mem.indexOfScalarPos(u8, buffer[0..body_start], length_at, '\r').?], 10);
    while (used < body_start + length) used += try std.posix.read(fd, buffer[used..]);
    return .{ .head = buffer[0..body_start], .body = buffer[body_start .. body_start + length] };
}

/// Writes one whole response; a peer that already left ends it quietly.
pub fn respond(fd: std.posix.fd_t, status: []const u8, kind: []const u8, extra: []const u8, body: []const u8) void {
    var header: [512]u8 = undefined;
    const head = std.fmt.bufPrint(&header, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n{s}\r\n", .{ status, kind, body.len, extra }) catch unreachable;
    for ([_][]const u8{ head, body }) |bytes| {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const count = std.c.send(fd, bytes[sent..].ptr, bytes.len - sent, socket_os.send_flags);
            if (count <= 0) return;
            sent += @intCast(count);
        }
    }
}

/// Answers with exact content bytes, framed as a whole content stream.
pub fn respondContent(fd: std.posix.fd_t, bytes: []const u8) void {
    var extra: [128]u8 = undefined;
    respond(fd, "200 OK", "application/octet-stream", std.fmt.bufPrint(&extra, "X-Rui-Content-Bytes: {d}\r\nX-Rui-Next-Offset: {d}\r\n", .{ bytes.len, bytes.len }) catch unreachable, bytes);
}

/// Answers with an ordinary refusal.
pub fn refuse(fd: std.posix.fd_t, kind: protocol.ErrorType, code: []const u8) void {
    var out: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    protocol.writeShape(&writer, protocol.error_reply, .{ kind, code }) catch unreachable;
    respond(fd, "409 Conflict", "application/json", "", writer.buffered());
}
