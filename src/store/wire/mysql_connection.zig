//! A blocking connection to MySQL: the socket, TLS and deadlines around
//! the sans-I/O client in `mysql.zig`. The thread that calls it does the
//! I/O and waits on it; it starts no thread.
//!
//! Memory is fixed when the connection is made: a 16 KiB receive buffer, a
//! send buffer that holds one 16 KiB batch, the client's 2 KiB handshake
//! buffer, and two TLS record buffers. Nothing grows with a row or a
//! statement: rows stream from the receive buffer (an event's slices stay
//! valid until the next call), and a statement longer than a batch streams
//! through the send buffer behind a header that states its length.
//!
//! Every wait on the socket ends after `deadline_ms` without progress, so a
//! peer that stops answering cannot hold the caller longer. That, the end
//! of the stream, a reset, a TLS failure and every client error lose the
//! connection: each later call returns `error.ConnectionLost`, and its
//! owner closes it.
//!
//! Session settings (`schema.mysql_session`) are the owner's to send.
const std = @import("std");
const builtin = @import("builtin");
pub const mysql = @import("mysql.zig");
pub const tls = @import("tls.zig");

/// How long one wait on the socket may last. Above InnoDB's default lock
/// wait (50 s), so a statement waiting on a lock ends with the server's
/// error rather than a lost connection.
pub const round_deadline_ms: u32 = 60_000;

/// The statement text one COM_QUERY batch holds.
pub const batch_bytes = 16 * 1024;

const prefix_len = 5;

pub const Address = union(enum) {
    /// A Unix socket's path.
    unix_socket: []const u8,
    /// TCP under TLS. `host`, a DNS name or an IP literal, is checked
    /// against the server's certificate.
    tcp_tls: struct { host: []const u8, port: u16, trust: tls.Trust },
    /// Plaintext TCP, for tests: the client never sends a password over it,
    /// so only a login the server's cache already holds succeeds.
    tcp: struct { host: []const u8, port: u16 },
};

/// Borrowed until `open` returns.
pub const Options = struct {
    address: Address,
    user: []const u8,
    password: []const u8,
    database: []const u8,
    deadline_ms: u32 = round_deadline_ms,
};

pub const Error = error{
    /// The end of the stream, a reset, a failed send or receive, or TLS
    /// failing after its handshake. Also every call after any error.
    ConnectionLost,
    /// No byte moved within `deadline_ms`.
    DeadlineExceeded,
    /// The server's certificate failed verification.
    UntrustedPeer,
    TlsFailed,
} || mysql.Error;

pub const OpenError = Error || mysql.OptionsError || tls.ContextError || error{
    /// The server refused the login; its error went to `refusal`.
    LoginRefused,
    /// No address of the host took the connection.
    ConnectFailed,
    HostNotFound,
    InvalidHost,
    /// Descriptors or memory ran out.
    SystemResources,
};

pub const Connection = struct {
    fd: std.c.fd_t,
    deadline_ms: u32,
    client: mysql.Client,
    lost: bool,
    /// The cause of the last `error.WriteFailed` from `writer`.
    write_error: ?Error,
    /// COM_QUERY packets sent, for tests that count round trips.
    queries: u64,
    inbox: [mysql.receive_buffer_min]u8,
    in_start: usize,
    in_end: usize,
    handshake: [mysql.send_buffer_min]u8,
    /// The COM_QUERY prefix, then a batch's text; or the part of a
    /// streamed statement not yet sent.
    send_buffer: [prefix_len + batch_bytes]u8,
    writer: std.Io.Writer,
    /// Bytes of a streamed statement still due, the buffered ones included;
    /// null while a batch fills, which never drains.
    stream_left: ?usize,
    context: ?tls.Context,
    session: ?tls.Session,
    /// After `.start_tls`: every later byte crosses TLS.
    tls_active: bool,
    cipher_in: [tls.max_record_bytes]u8,
    cipher_len: usize,
    cipher_out: [tls.max_record_bytes]u8,

    /// Connects and logs in. When the server refuses the login, writes its
    /// error (`mysql.Event.format`) to `refusal` and returns
    /// `error.LoginRefused`. On any error the connection is closed.
    pub fn open(self: *Connection, options: Options, refusal: *std.Io.Writer) OpenError!void {
        self.fd = -1;
        self.deadline_ms = options.deadline_ms;
        self.lost = false;
        self.write_error = null;
        self.queries = 0;
        self.in_start = 0;
        self.in_end = 0;
        self.writer = .{ .vtable = &.{ .drain = drain }, .buffer = &self.send_buffer };
        self.stream_left = null;
        self.context = null;
        self.session = null;
        self.tls_active = false;
        self.cipher_len = 0;
        errdefer self.release();
        self.client = try .init(.{
            .user = options.user,
            .password = options.password,
            .database = options.database,
            .transport = switch (options.address) {
                .unix_socket => .unix_socket,
                .tcp_tls => .tcp_tls,
                .tcp => .tcp,
            },
        });
        switch (options.address) {
            .unix_socket => |path| try self.connectUnix(path),
            .tcp => |tcp| try self.connectTcp(tcp.host, tcp.port),
            .tcp_tls => |tcp| {
                self.context = try .init(tcp.trust);
                const kind: tls.HostKind = if (std.Io.net.IpAddress.parseLiteral(tcp.host)) |_| .ip_literal else |_| .dns_name;
                self.session = try .init(&self.context.?, tcp.host, kind);
                try self.connectTcp(tcp.host, tcp.port);
            },
        }
        const event = try self.next();
        if (event == .ready) return;
        // The refusal is a diagnostic: LoginRefused is the outcome whether
        // or not it could be written.
        refusal.print("{f}", .{event}) catch {};
        return error.LoginRefused;
    }

    /// Sends COM_QUIT when the client is ready, then closes. Nothing is
    /// reported: the descriptor and the TLS state are released either way.
    pub fn close(self: *Connection) void {
        if (!self.lost and self.client.isReady()) self.transmit(&self.client.quit()) catch {};
        self.release();
    }

    pub fn isReady(self: *const Connection) bool {
        return !self.lost and self.client.isReady();
    }

    /// The next event other than a send, which it performs. Slices in the
    /// event stay valid until the next call.
    pub fn next(self: *Connection) Error!mysql.Event {
        if (self.lost) return error.ConnectionLost;
        errdefer self.lost = true;
        while (true) {
            const step = try self.client.read(self.inbox[self.in_start..self.in_end], &self.handshake);
            self.in_start += step.consumed;
            if (step.event) |event| switch (event) {
                .send => |n| try self.transmit(self.handshake[0..n]),
                .start_tls => |n| try self.startTls(n),
                else => return event,
            } else if (step.consumed == 0) try self.fill();
        }
    }

    /// Room left for text in the open batch.
    pub fn batchRoom(self: *const Connection) usize {
        return self.send_buffer.len - @max(self.writer.end, prefix_len);
    }

    /// Text in the open batch.
    pub fn batchLen(self: *const Connection) usize {
        return self.writer.end -| prefix_len;
    }

    /// The writer of the open batch, opening one if none is. The caller
    /// writes at most `batchRoom()` bytes: a batch never drains.
    pub fn batch(self: *Connection) *std.Io.Writer {
        std.debug.assert(self.isReady() and self.stream_left == null);
        if (self.writer.end == 0) self.writer.end = prefix_len;
        return &self.writer;
    }

    /// Sends the open batch as one COM_QUERY. Its results arrive through
    /// `next` until the client is ready again.
    pub fn sendBatch(self: *Connection) Error!void {
        if (self.lost) return error.ConnectionLost;
        errdefer self.lost = true;
        std.debug.assert(self.isReady() and self.stream_left == null and self.batchLen() > 0);
        const end = self.writer.end;
        self.writer.end = 0;
        // A batch is far below the single-packet limit.
        self.send_buffer[0..prefix_len].* = self.client.query(end - prefix_len) catch unreachable;
        self.queries += 1;
        try self.transmit(self.send_buffer[0..end]);
    }

    /// Starts a COM_QUERY of `text_len` bytes, which the caller writes to
    /// the returned writer and ends with `endQuery`. The text streams
    /// through the send buffer, so it may be longer than a batch. No batch
    /// may be open.
    pub fn beginQuery(self: *Connection, text_len: usize) (Error || mysql.QueryError)!*std.Io.Writer {
        if (self.lost) return error.ConnectionLost;
        std.debug.assert(self.isReady() and self.writer.end == 0);
        self.send_buffer[0..prefix_len].* = try self.client.query(text_len);
        self.queries += 1;
        self.writer.end = prefix_len;
        self.stream_left = prefix_len + text_len;
        return &self.writer;
    }

    /// Sends what the streamed statement still buffers. When the writer
    /// failed, returns why. Exactly the stated length must have been
    /// written.
    pub fn endQuery(self: *Connection) Error!void {
        if (self.write_error) |err| return err;
        if (self.lost) return error.ConnectionLost;
        errdefer self.lost = true;
        try self.flushStream();
        std.debug.assert(self.stream_left.? == 0);
        self.stream_left = null;
    }

    /// Sends `text` as one COM_QUERY.
    pub fn query(self: *Connection, text: []const u8) (Error || mysql.QueryError)!void {
        const w = try self.beginQuery(text.len);
        // A failed write's cause comes from endQuery.
        w.writeAll(text) catch {};
        try self.endQuery();
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        _ = data;
        _ = splat;
        const self: *Connection = @alignCast(@fieldParentPtr("writer", w));
        self.flushStream() catch |err| {
            self.write_error = err;
            self.lost = true;
            return error.WriteFailed;
        };
        // The buffer is empty again; the writer copies the data into it.
        return 0;
    }

    fn flushStream(self: *Connection) Error!void {
        const bytes = self.send_buffer[0..self.writer.end];
        // A batch never drains, and a statement is no longer than it said.
        std.debug.assert(bytes.len <= self.stream_left.?);
        try self.transmit(bytes);
        self.stream_left.? -= bytes.len;
        self.writer.end = 0;
    }

    fn release(self: *Connection) void {
        self.lost = true;
        if (self.session) |*session| session.deinit();
        if (self.context) |*context| context.deinit();
        self.session = null;
        self.context = null;
        // A failed close leaves nothing to retry: the descriptor is
        // released either way.
        if (self.fd >= 0) _ = std.c.close(self.fd);
        self.fd = -1;
    }

    fn connectUnix(self: *Connection, path: []const u8) OpenError!void {
        var address: std.c.sockaddr.un = std.mem.zeroes(std.c.sockaddr.un);
        if (path.len == 0 or path.len >= address.path.len or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidHost;
        address.family = std.c.AF.UNIX;
        @memcpy(address.path[0..path.len], path);
        if (@hasField(std.c.sockaddr.un, "len")) address.len = @sizeOf(std.c.sockaddr.un);
        try self.connectTo(std.c.AF.UNIX, @ptrCast(&address), @sizeOf(std.c.sockaddr.un));
    }

    /// Resolves `host` with the system resolver, which blocks for its own
    /// configured time, then tries each address in turn.
    fn connectTcp(self: *Connection, host: []const u8, port: u16) OpenError!void {
        var host_z: [256]u8 = undefined;
        if (host.len == 0 or host.len >= host_z.len or std.mem.indexOfScalar(u8, host, 0) != null) return error.InvalidHost;
        @memcpy(host_z[0..host.len], host);
        host_z[host.len] = 0;
        var port_z: [6]u8 = undefined;
        const service = std.fmt.bufPrintSentinel(&port_z, "{d}", .{port}, 0) catch unreachable;
        var hints: std.c.addrinfo = std.mem.zeroes(std.c.addrinfo);
        hints.family = std.c.AF.UNSPEC;
        hints.socktype = std.c.SOCK.STREAM;
        hints.flags = .{ .NUMERICSERV = true };
        var found: ?*std.c.addrinfo = null;
        if (@intFromEnum(std.c.getaddrinfo(host_z[0..host.len :0], service, &hints, &found)) != 0) return error.HostNotFound;
        defer if (found) |list| std.c.freeaddrinfo(list);
        var entry = found;
        while (entry) |info| : (entry = info.next) {
            const address = info.addr orelse continue;
            self.connectTo(@intCast(info.family), address, info.addrlen) catch |err| switch (err) {
                error.ConnectFailed, error.DeadlineExceeded => continue,
                else => return err,
            };
            return;
        }
        return error.ConnectFailed;
    }

    /// Connects a new non-blocking socket, waiting at most the deadline.
    fn connectTo(self: *Connection, family: c_uint, address: *const std.c.sockaddr, len: std.c.socklen_t) OpenError!void {
        const fd = std.c.socket(family, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SystemResources;
        errdefer {
            _ = std.c.close(fd);
            self.fd = -1;
        }
        self.fd = fd;
        if (!configure(fd, family != std.c.AF.UNIX)) return error.SystemResources;
        while (true) switch (std.posix.errno(std.c.connect(fd, address, len))) {
            .SUCCESS => return,
            .INTR => continue,
            .INPROGRESS, .AGAIN => break,
            .NOBUFS, .NOMEM, .MFILE, .NFILE => return error.SystemResources,
            else => return error.ConnectFailed,
        };
        self.wait(std.c.POLL.OUT) catch |err| return switch (err) {
            error.DeadlineExceeded => error.DeadlineExceeded,
            else => error.ConnectFailed,
        };
        var result: c_int = 0;
        var result_len: std.c.socklen_t = @sizeOf(c_int);
        if (std.c.getsockopt(fd, std.c.SOL.SOCKET, std.c.SO.ERROR, @ptrCast(&result), &result_len) != 0 or result != 0) return error.ConnectFailed;
    }

    /// Waits until the socket is ready for `events`, or an error or hangup
    /// that the following send or receive then reports.
    fn wait(self: *Connection, events: i16) Error!void {
        var fds = [_]std.c.pollfd{.{ .fd = self.fd, .events = events, .revents = 0 }};
        while (true) {
            const ready = std.c.poll(&fds, 1, @intCast(@min(self.deadline_ms, std.math.maxInt(c_int))));
            if (ready > 0) return;
            if (ready == 0) return error.DeadlineExceeded;
            if (std.posix.errno(ready) != .INTR) return error.ConnectionLost;
        }
    }

    fn sendRaw(self: *Connection, bytes: []const u8) Error!void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const count = std.c.send(self.fd, bytes[sent..].ptr, bytes.len - sent, send_flags);
            switch (std.posix.errno(count)) {
                .SUCCESS => sent += @intCast(count),
                .INTR => {},
                .AGAIN => try self.wait(std.c.POLL.OUT),
                else => return error.ConnectionLost,
            }
        }
    }

    fn receiveRaw(self: *Connection, buffer: []u8) Error!usize {
        std.debug.assert(buffer.len > 0);
        while (true) {
            const count = std.c.recv(self.fd, buffer.ptr, buffer.len, 0);
            switch (std.posix.errno(count)) {
                .SUCCESS => return if (count == 0) error.ConnectionLost else @intCast(count),
                .INTR => {},
                .AGAIN => try self.wait(std.c.POLL.IN),
                else => return error.ConnectionLost,
            }
        }
    }

    /// Sends plaintext, through TLS once it started.
    fn transmit(self: *Connection, plain: []const u8) Error!void {
        if (!self.tls_active) return self.sendRaw(plain);
        var rest = plain;
        while (rest.len > 0) {
            var wire: tls.Wire = .{ .in = &.{}, .out = &self.cipher_out };
            // A retry after want_write passes the same bytes, as OpenSSL requires.
            const transfer = self.session.?.write(&wire, rest);
            try self.sendRaw(wire.out[0..wire.out_used]);
            switch (transfer) {
                .bytes => |count| rest = rest[count..],
                .want_write => {},
                .want_read, .closed => return error.ConnectionLost,
            }
        }
    }

    /// Reads more plaintext behind the unconsumed bytes, moved to the front.
    fn fill(self: *Connection) Error!void {
        if (self.in_start > 0) {
            std.mem.copyForwards(u8, &self.inbox, self.inbox[self.in_start..self.in_end]);
            self.in_end -= self.in_start;
            self.in_start = 0;
        }
        // The client never needs more than the buffer holds.
        if (self.in_end == self.inbox.len) return error.ProtocolViolation;
        if (!self.tls_active) {
            self.in_end += try self.receiveRaw(self.inbox[self.in_end..]);
            return;
        }
        while (true) {
            var wire: tls.Wire = .{ .in = self.cipher_in[0..self.cipher_len], .out = &self.cipher_out };
            const transfer = self.session.?.read(&wire, self.inbox[self.in_end..]);
            try self.settle(&wire);
            switch (transfer) {
                .bytes => |count| {
                    self.in_end += count;
                    return;
                },
                .want_read => try self.receiveCipher(),
                .want_write => {},
                .closed => return error.ConnectionLost,
            }
        }
    }

    fn receiveCipher(self: *Connection) Error!void {
        // A record fits the buffer whole, so a full buffer is a peer that
        // breaks TLS.
        if (self.cipher_len == self.cipher_in.len) return error.ConnectionLost;
        self.cipher_len += try self.receiveRaw(self.cipher_in[self.cipher_len..]);
    }

    /// Sends what OpenSSL wrote and drops the ciphertext it read.
    fn settle(self: *Connection, wire: *const tls.Wire) Error!void {
        try self.sendRaw(wire.out[0..wire.out_used]);
        if (wire.in_used == 0) return;
        std.mem.copyForwards(u8, &self.cipher_in, self.cipher_in[wire.in_used..self.cipher_len]);
        self.cipher_len -= wire.in_used;
    }

    /// Sends the SSLRequest in plaintext, then completes the handshake.
    fn startTls(self: *Connection, request_len: usize) Error!void {
        // The server sends nothing between its greeting and our ClientHello.
        if (self.in_start != self.in_end) return error.ProtocolViolation;
        try self.sendRaw(self.handshake[0..request_len]);
        const session = &self.session.?;
        while (true) {
            var wire: tls.Wire = .{ .in = self.cipher_in[0..self.cipher_len], .out = &self.cipher_out };
            const progress = session.handshake(&wire);
            try self.settle(&wire);
            switch (progress) {
                .done => break,
                .want_read => try self.receiveCipher(),
                .want_write => {},
                .untrusted_peer => return error.UntrustedPeer,
                .failed => return error.TlsFailed,
            }
        }
        self.tls_active = true;
    }
};

const send_flags: c_int = if (builtin.os.tag == .linux) std.c.MSG.NOSIGNAL else 0;

/// Close-on-exec, non-blocking, and over TCP no Nagle delay; on Darwin, no
/// SIGPIPE when the peer went away.
fn configure(fd: std.c.fd_t, tcp: bool) bool {
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

// Tests replay the client's captured exchanges (`mysql.Capture`) through a
// peer thread on a real socket. The peer checks every byte the connection
// sends against the capture and records what went wrong before it closes,
// so joining it after the connection returns cannot change the result.

const Peer = struct {
    listener: std.c.fd_t,
    steps: []const Step,
    thread: std.Thread = undefined,
    /// What went wrong, read after `join`.
    failure: ?[]const u8 = null,
    failed_step: usize = 0,

    const Step = union(enum) {
        send: []const u8,
        expect: []const u8,
        /// Closes the connection without waiting for the client.
        close,
    };

    fn unix(path: [:0]const u8, steps: []const Step) !Peer {
        const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.Socket;
        errdefer _ = std.c.close(fd);
        var address: std.c.sockaddr.un = std.mem.zeroes(std.c.sockaddr.un);
        address.family = std.c.AF.UNIX;
        @memcpy(address.path[0..path.len], path);
        if (std.c.bind(fd, @ptrCast(&address), @sizeOf(std.c.sockaddr.un)) != 0) return error.Bind;
        if (std.c.listen(fd, 1) != 0) return error.Listen;
        return .{ .listener = fd, .steps = steps };
    }

    /// A loopback TCP listener; `port` receives its port.
    fn tcp(port: *u16, steps: []const Step) !Peer {
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.Socket;
        errdefer _ = std.c.close(fd);
        var address: std.c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (std.c.bind(fd, @ptrCast(&address), @sizeOf(std.c.sockaddr.in)) != 0) return error.Bind;
        if (std.c.listen(fd, 1) != 0) return error.Listen;
        var len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
        if (std.c.getsockname(fd, @ptrCast(&address), &len) != 0) return error.Bind;
        port.* = std.mem.bigToNative(u16, address.port);
        return .{ .listener = fd, .steps = steps };
    }

    fn start(self: *Peer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Waits for the peer, then reports what it saw go wrong.
    fn join(self: *Peer) !void {
        self.thread.join();
        _ = std.c.close(self.listener);
        if (self.failure) |failure| {
            std.debug.print("peer, step {d}: {s}\n", .{ self.failed_step, failure });
            return error.PeerFailed;
        }
    }

    fn run(self: *Peer) void {
        self.failure = self.serve();
    }

    fn serve(self: *Peer) ?[]const u8 {
        // Bounded, so a broken test fails instead of hanging.
        var fds = [_]std.c.pollfd{.{ .fd = self.listener, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, 10_000) != 1) return "no connection arrived";
        const fd = std.c.accept(self.listener, null, null);
        if (fd < 0) return "accept failed";
        defer _ = std.c.close(fd);
        const timeout: std.c.timeval = .{ .sec = 10, .usec = 0 };
        _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, @ptrCast(&timeout), @sizeOf(std.c.timeval));
        for (self.steps, 0..) |step, index| {
            self.failed_step = index;
            switch (step) {
                .send => |bytes| {
                    var sent: usize = 0;
                    while (sent < bytes.len) {
                        const count = std.c.send(fd, bytes[sent..].ptr, bytes.len - sent, send_flags);
                        if (count <= 0) return "send failed";
                        sent += @intCast(count);
                    }
                },
                .expect => |bytes| {
                    var seen: usize = 0;
                    var buffer: [4096]u8 = undefined;
                    while (seen < bytes.len) {
                        const count = std.c.recv(fd, &buffer, @min(buffer.len, bytes.len - seen), 0);
                        if (count <= 0) return "the client stopped before sending what the capture holds";
                        const got = buffer[0..@intCast(count)];
                        if (!std.mem.eql(u8, got, bytes[seen..][0..got.len])) return "the client sent other bytes than the capture";
                        seen += got.len;
                    }
                },
                .close => return null,
            }
        }
        self.failed_step = self.steps.len;
        // The client closes next; a byte before that is one the script lacks.
        var extra: [1]u8 = undefined;
        if (std.c.recv(fd, &extra, 1, 0) != 0) return "the client sent more than the capture holds";
        return null;
    }
};

/// `capture` as a peer's script: the server's chunks sent, the client's expected.
fn scriptOf(capture: mysql.Capture, steps: []Peer.Step) []const Peer.Step {
    for (capture.chunks, steps[0..capture.chunks.len]) |chunk, *step| step.* = switch (chunk[0]) {
        .server => .{ .send = chunk[1] },
        .client => .{ .expect = chunk[1] },
    };
    return steps[0..capture.chunks.len];
}

/// Events as text, one per line, with a value's bytes joined to it.
const Transcript = struct {
    text: std.Io.Writer.Allocating,
    value_open: bool = false,

    fn init() Transcript {
        return .{ .text = .init(std.testing.allocator) };
    }

    fn deinit(self: *Transcript) void {
        self.text.deinit();
    }

    fn add(self: *Transcript, event: mysql.Event) !void {
        const w = &self.text.writer;
        if (event == .bytes) {
            if (self.value_open) try w.writeByte(' ');
            self.value_open = false;
            return w.writeAll(event.bytes);
        }
        self.value_open = event == .value and event.value != null;
        if (self.text.written().len > 0) try w.writeByte('\n');
        try w.print("{f}", .{event});
    }

    /// Every event until the client is ready again.
    fn untilReady(self: *Transcript, connection: *Connection) !void {
        while (!connection.isReady()) try self.add(try connection.next());
    }
};

/// Logs in as `capture` did, runs each query it recorded, then closes.
fn replay(capture: mysql.Capture, address: Address, transcript: *Transcript) !void {
    const connection = try std.testing.allocator.create(Connection);
    defer std.testing.allocator.destroy(connection);
    var refusal: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer refusal.deinit();
    try connection.open(.{ .address = address, .user = capture.user, .password = capture.password, .database = "rui", .deadline_ms = 10_000 }, &refusal.writer);
    defer connection.close();
    for (capture.chunks) |chunk| {
        const bytes = chunk[1];
        // A COM_QUERY is the only client packet with sequence id 0 and command 3.
        if (chunk[0] != .client or bytes[3] != 0 or bytes[4] != 3) continue;
        try connection.query(bytes[5..]);
        try transcript.untilReady(connection);
    }
}

fn tmpSocket(tmp: *const std.testing.TmpDir, buffer: []u8) ![:0]const u8 {
    return std.fmt.bufPrintSentinel(buffer, ".zig-cache/tmp/{s}/mysqld.sock", .{tmp.sub_path}, 0);
}

test "a Unix socket connection sends the password, and a multi-statement query reports each statement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try tmpSocket(&tmp, &path_buffer);
    var steps: [16]Peer.Step = undefined;
    var peer: Peer = try .unix(path, scriptOf(mysql.multi_statement, &steps));
    try peer.start();
    var transcript: Transcript = .init();
    defer transcript.deinit();
    const replayed = replay(mysql.multi_statement, .{ .unix_socket = path }, &transcript);
    try peer.join();
    try replayed;
    try std.testing.expectEqualStrings(
        \\ok 0 more no_backslash_escapes
        \\ok 0 more no_backslash_escapes
        \\ok 2 more no_backslash_escapes
        \\ok 1 more no_backslash_escapes
        \\columns 3
        \\column id longlong not_null
        \\column v var_string not_null binary
        \\column n longlong
        \\row
        \\value 1 1
        \\value 2 hi
        \\null
        \\row
        \\value 1 2
        \\value 0
        \\value 1 7
        \\rows_end no_backslash_escapes
    , transcript.text.written());
}

test "a TCP connection logs in with a cached scramble, and an error ends its query" {
    var steps: [16]Peer.Step = undefined;
    var port: u16 = 0;
    var peer: Peer = try .tcp(&port, scriptOf(mysql.cached_tcp, &steps));
    try peer.start();
    var transcript: Transcript = .init();
    defer transcript.deinit();
    const replayed = replay(mysql.cached_tcp, .{ .tcp = .{ .host = "127.0.0.1", .port = port } }, &transcript);
    try peer.join();
    try replayed;
    try std.testing.expectEqualStrings(
        \\columns 1
        \\column CURRENT_USER() var_string
        \\row
        \\value 5 rui@%
        \\rows_end
    , transcript.text.written());

    var error_steps: [16]Peer.Step = undefined;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try tmpSocket(&tmp, &path_buffer);
    var error_peer: Peer = try .unix(path, scriptOf(mysql.error_stops, &error_steps));
    try error_peer.start();
    var error_transcript: Transcript = .init();
    defer error_transcript.deinit();
    const error_replayed = replay(mysql.error_stops, .{ .unix_socket = path }, &error_transcript);
    try error_peer.join();
    try error_replayed;
    try std.testing.expectEqualStrings(
        \\ok 1 more
        \\err 1062 23000 Duplicate entry '3' for key 't.PRIMARY'
        \\columns 1
        \\column COUNT(*) longlong not_null binary
        \\row
        \\value 1 0
        \\rows_end
    , error_transcript.text.written());
}

test "a refused login reports the server's error and closes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try tmpSocket(&tmp, &path_buffer);
    var steps: [16]Peer.Step = undefined;
    const capture = mysql.wrong_password_unix;
    var peer: Peer = try .unix(path, scriptOf(capture, &steps));
    try peer.start();
    const connection = try std.testing.allocator.create(Connection);
    defer std.testing.allocator.destroy(connection);
    var refusal: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer refusal.deinit();
    const opened = connection.open(.{ .address = .{ .unix_socket = path }, .user = capture.user, .password = capture.password, .database = "rui" }, &refusal.writer);
    try peer.join();
    try std.testing.expectError(error.LoginRefused, opened);
    try std.testing.expectEqualStrings("err 1045 28000 Access denied for user 'rui'@'localhost' (using password: YES)", refusal.written());
    try std.testing.expectEqual(-1, connection.fd);
}

/// An OK packet with sequence id `sequence`, `more` results following.
fn okPacket(sequence: u8, affected: u8, more: bool) [11]u8 {
    return .{ 7, 0, 0, sequence, 0, affected, 0, if (more) 0x0a else 0x02, 0, 0, 0 };
}

/// The capture's login, as a script's first steps.
const cached_login = [_]Peer.Step{
    .{ .send = mysql.cached_tcp.chunks[0][1] },
    .{ .expect = mysql.cached_tcp.chunks[1][1] },
    .{ .send = mysql.cached_tcp.chunks[2][1] },
};
const quit = [_]u8{ 1, 0, 0, 0, 1 };

fn openCached(connection: *Connection, path: []const u8, deadline_ms: u32) !void {
    var buffer: [256]u8 = undefined;
    var refusal: std.Io.Writer = .fixed(&buffer);
    try connection.open(.{
        .address = .{ .unix_socket = path },
        .user = "rui",
        .password = mysql.cached_tcp.password,
        .database = "rui",
        .deadline_ms = deadline_ms,
    }, &refusal);
}

test "a statement longer than the send buffer streams behind its length, and a batch goes as one packet" {
    const allocator = std.testing.allocator;
    const long_len = 3 * batch_bytes + 17;
    const long = try allocator.alloc(u8, prefix_len + long_len);
    defer allocator.free(long);
    std.mem.writeInt(u24, long[0..3], long_len + 1, .little);
    long[3] = 0;
    long[4] = 3;
    for (long[prefix_len..], 0..) |*byte, i| byte.* = 'a' + @as(u8, @intCast(i % 26));
    const batch_text = "SET @a=1;SET @b=2";
    const batched = [_]u8{ batch_text.len + 1, 0, 0, 0, 3 } ++ batch_text.*;
    const first_ok = okPacket(1, 0, false);
    const more_ok = okPacket(1, 0, true);
    const last_ok = okPacket(2, 0, false);
    const steps = cached_login ++ [_]Peer.Step{
        .{ .expect = long },     .{ .send = &first_ok },
        .{ .expect = &batched }, .{ .send = &more_ok },
        .{ .send = &last_ok },   .{ .expect = &quit },
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try tmpSocket(&tmp, &path_buffer);
    var peer: Peer = try .unix(path, &steps);
    try peer.start();
    const connection = try allocator.create(Connection);
    defer allocator.destroy(connection);
    var transcript: Transcript = .init();
    defer transcript.deinit();
    const driven: anyerror!void = drive: {
        openCached(connection, path, 10_000) catch |err| break :drive err;
        defer connection.close();
        connection.query(long[prefix_len..]) catch |err| break :drive err;
        transcript.untilReady(connection) catch |err| break :drive err;
        const w = connection.batch();
        w.writeAll("SET @a=1;") catch |err| break :drive err;
        w.writeAll("SET @b=2") catch |err| break :drive err;
        std.testing.expectEqual(batch_bytes - batch_text.len, connection.batchRoom()) catch |err| break :drive err;
        connection.sendBatch() catch |err| break :drive err;
        transcript.untilReady(connection) catch |err| break :drive err;
        std.testing.expectEqual(2, connection.queries) catch |err| break :drive err;
        break :drive {};
    };
    try peer.join();
    try driven;
    try std.testing.expectEqualStrings("ok 0\nok 0 more\nok 0", transcript.text.written());
}

test "no byte within the deadline loses the connection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try tmpSocket(&tmp, &path_buffer);
    // The peer sends no greeting; it waits for the client to close.
    var peer: Peer = try .unix(path, &.{});
    try peer.start();
    const connection = try std.testing.allocator.create(Connection);
    defer std.testing.allocator.destroy(connection);
    const opened = openCached(connection, path, 20);
    try peer.join();
    try std.testing.expectError(error.DeadlineExceeded, opened);
}

test "the end of the stream mid-result loses the connection for every later call" {
    const select = [_]u8{ 9, 0, 0, 0, 3 } ++ "SELECT 1".*;
    const steps = cached_login ++ [_]Peer.Step{
        .{ .expect = &select },
        // A result set of one column, then nothing.
        .{ .send = &.{ 1, 0, 0, 1, 1 } },
        .close,
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try tmpSocket(&tmp, &path_buffer);
    var peer: Peer = try .unix(path, &steps);
    try peer.start();
    const connection = try std.testing.allocator.create(Connection);
    defer std.testing.allocator.destroy(connection);
    const driven: anyerror!void = drive: {
        openCached(connection, path, 10_000) catch |err| break :drive err;
        defer connection.close();
        connection.query("SELECT 1") catch |err| break :drive err;
        std.testing.expectEqual(mysql.Event{ .columns = 1 }, connection.next() catch |err| break :drive err) catch |err| break :drive err;
        std.testing.expectError(error.ConnectionLost, connection.next()) catch |err| break :drive err;
        std.testing.expectError(error.ConnectionLost, connection.next()) catch |err| break :drive err;
        std.testing.expect(!connection.isReady()) catch |err| break :drive err;
        break :drive {};
    };
    try peer.join();
    try driven;
}
