//! A blocking driver for `mysql.Client`, for tests only: the wire client's
//! live tests and the Store's live dialect check share it. It reaches the
//! server over a Unix socket or plaintext loopback TCP and never starts TLS.
const std = @import("std");
/// The client it drives, for a test built with this file as its module root.
pub const mysql = @import("mysql.zig");

/// Where the server listens: a Unix socket's path, or a TCP port on
/// 127.0.0.1. It also names the transport the client is told it runs on.
pub const Address = union(enum) {
    unix_socket: []const u8,
    tcp: u16,
};

/// Borrowed until `open` returns.
pub const Login = struct {
    user: []const u8,
    password: []const u8,
    database: []const u8,
};

pub const Driver = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    client: mysql.Client,
    read_buffer: [mysql.receive_buffer_min]u8,
    write_buffer: [256]u8,
    out: [mysql.send_buffer_min]u8,

    /// Connects and logs in. When the server refuses the login, writes the
    /// refusal's event (`mysql.Event.format`) to `refusal`, closes the
    /// connection and returns `error.LoginRefused`. Any other error also
    /// leaves the connection closed.
    pub fn open(self: *Driver, io: std.Io, address: Address, login: Login, refusal: *std.Io.Writer) !void {
        self.io = io;
        self.stream = switch (address) {
            .unix_socket => |path| try (try std.Io.net.UnixAddress.init(path)).connect(io),
            .tcp => |port| try (std.Io.net.IpAddress{ .ip4 = .loopback(port) }).connect(io, .{ .mode = .stream }),
        };
        errdefer self.stream.close(io);
        self.reader = self.stream.reader(io, &self.read_buffer);
        self.writer = self.stream.writer(io, &self.write_buffer);
        self.client = try .init(.{
            .user = login.user,
            .password = login.password,
            .database = login.database,
            .transport = switch (address) {
                .unix_socket => .unix_socket,
                .tcp => .tcp,
            },
        });
        const event = try self.next();
        if (event == .ready) return;
        try refusal.print("{f}", .{event});
        return error.LoginRefused;
    }

    /// Sends COM_QUIT and closes the connection. The client must be ready.
    pub fn close(self: *Driver) !void {
        defer self.stream.close(self.io);
        try self.writer.interface.writeAll(&self.client.quit());
        try self.writer.interface.flush();
    }

    /// The next event other than a send, which it performs. Slices in the
    /// event stay valid until the next call.
    pub fn next(self: *Driver) !mysql.Event {
        const in = &self.reader.interface;
        while (true) {
            const step = try self.client.read(in.buffered(), &self.out);
            in.toss(step.consumed);
            if (step.event) |event| switch (event) {
                .send => |n| {
                    try self.writer.interface.writeAll(self.out[0..n]);
                    try self.writer.interface.flush();
                },
                .start_tls => return error.TlsNotDriven,
                else => return event,
            } else if (step.consumed == 0) try in.fillMore();
        }
    }

    /// Sends `text` as one COM_QUERY. Its results arrive through `next`
    /// until the client is ready again.
    pub fn query(self: *Driver, text: []const u8) !void {
        try self.writer.interface.writeAll(&try self.client.query(text.len));
        try self.writer.interface.writeAll(text);
        try self.writer.interface.flush();
    }
};
