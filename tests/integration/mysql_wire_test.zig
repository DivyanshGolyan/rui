//! The MySQL wire client against a real MySQL 8.4 server, through a blocking
//! driver that exists only here. mysql_wire_integration.py starts the server
//! and passes its socket, port and passwords in the environment; this binary
//! fails rather than skips when they are missing.
//!
//! The server starts with an empty authentication cache, so the first test
//! sees the cold-cache logins before any login fills it. Tests run in
//! declaration order.
const std = @import("std");
const mysql = @import("mysql_wire");

const Server = struct {
    socket: []const u8,
    port: u16,
    password: []const u8,
    root_password: []const u8,
    environ: std.process.Environ.Map,

    fn init() !Server {
        var environ = try std.testing.environ.createMap(std.testing.allocator);
        errdefer environ.deinit();
        return .{
            .socket = environ.get("RUI_MYSQL_SOCKET") orelse return error.MissingServer,
            .port = try std.fmt.parseInt(u16, environ.get("RUI_MYSQL_PORT") orelse return error.MissingServer, 10),
            .password = environ.get("RUI_MYSQL_PASSWORD") orelse return error.MissingServer,
            .root_password = environ.get("RUI_MYSQL_ROOT_PASSWORD") orelse return error.MissingServer,
            .environ = environ,
        };
    }

    fn deinit(self: *Server) void {
        self.environ.deinit();
    }
};

const Login = struct {
    transport: mysql.Transport,
    user: []const u8 = "rui",
    password: []const u8,
};

const Driver = struct {
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    client: mysql.Client,
    read_buffer: [mysql.receive_buffer_min]u8,
    write_buffer: [256]u8,
    out: [mysql.send_buffer_min]u8,

    /// Stores a server's refusal of the login in `refusal`, or leaves it null
    /// once the client is ready. Closes the connection unless ready.
    fn open(self: *Driver, server: *const Server, login: Login, refusal: *?Transcript) !void {
        const io = std.testing.io;
        self.stream = switch (login.transport) {
            .unix_socket => try (try std.Io.net.UnixAddress.init(server.socket)).connect(io),
            .tcp => try (std.Io.net.IpAddress{ .ip4 = .loopback(server.port) }).connect(io, .{ .mode = .stream }),
            .tcp_tls => unreachable,
        };
        errdefer self.stream.close(io);
        self.reader = self.stream.reader(io, &self.read_buffer);
        self.writer = self.stream.writer(io, &self.write_buffer);
        self.client = try .init(.{ .user = login.user, .password = login.password, .database = "rui", .transport = login.transport });
        const event = try self.next();
        if (event == .ready) return;
        var transcript: Transcript = .init();
        try transcript.add(event);
        refusal.* = transcript;
        self.stream.close(io);
    }

    fn close(self: *Driver) !void {
        try self.writer.interface.writeAll(&self.client.quit());
        try self.writer.interface.flush();
        self.stream.close(std.testing.io);
    }

    /// The next event other than a send, which it performs.
    fn next(self: *Driver) !mysql.Event {
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

    /// Runs `text` and renders every event of its results.
    fn run(self: *Driver, text: []const u8) !Transcript {
        try self.writer.interface.writeAll(&try self.client.query(text.len));
        try self.writer.interface.writeAll(text);
        try self.writer.interface.flush();
        var transcript: Transcript = .init();
        errdefer transcript.deinit();
        while (!self.client.isReady()) try transcript.add(try self.next());
        return transcript;
    }
};

/// Events as text, one per line, with a value's bytes joined.
const Transcript = struct {
    text: std.Io.Writer.Allocating,
    chunks: usize = 0,
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
            self.chunks += 1;
            return w.writeAll(event.bytes);
        }
        self.value_open = event == .value and event.value != null;
        if (self.text.written().len > 0) try w.writeByte('\n');
        try w.print("{f}", .{event});
    }

    fn expect(self: *Transcript, expected: []const u8) !void {
        defer self.deinit();
        try std.testing.expectEqualStrings(expected, self.text.written());
    }
};

fn openReady(driver: *Driver, server: *const Server, login: Login) !void {
    var refusal: ?Transcript = null;
    try driver.open(server, login, &refusal);
    if (refusal) |*transcript| {
        defer transcript.deinit();
        std.debug.print("login refused: {s}\n", .{transcript.text.written()});
        return error.LoginRefused;
    }
}

test "logins: plaintext TCP with a cold cache, the full exchange over a Unix socket, then the cached scramble over TCP" {
    var server: Server = try .init();
    defer server.deinit();
    const driver = try std.testing.allocator.create(Driver);
    defer std.testing.allocator.destroy(driver);
    var refusal: ?Transcript = null;

    // No login has cached the account's hash, so the server asks for the
    // password itself, which plaintext TCP must not carry.
    try std.testing.expectError(error.AuthMethodRefused, driver.open(&server, .{ .transport = .tcp, .password = server.password }, &refusal));

    try driver.open(&server, .{ .transport = .unix_socket, .password = "not the password" }, &refusal);
    try std.testing.expect(refusal != null);
    try std.testing.expectStringStartsWith(refusal.?.text.written(), "err 1045 28000 Access denied for user 'rui'@'localhost'");
    refusal.?.deinit();
    refusal = null;

    try openReady(driver, &server, .{ .transport = .unix_socket, .password = server.password });
    try driver.close();

    // The Unix socket login cached the hash; the scramble alone now suffices.
    try openReady(driver, &server, .{ .transport = .tcp, .password = server.password });
    var transcript = try driver.run("SELECT CURRENT_USER()");
    try transcript.expect(
        \\columns 1
        \\column CURRENT_USER() var_string
        \\row
        \\value 5 rui@%
        \\rows_end
    );
    try driver.close();

    // FLUSH PRIVILEGES empties the cache, so plaintext TCP is refused again.
    try openReady(driver, &server, .{ .transport = .unix_socket, .user = "root", .password = server.root_password });
    transcript = try driver.run("FLUSH PRIVILEGES");
    try transcript.expect("ok 0");
    try driver.close();
    try std.testing.expectError(error.AuthMethodRefused, driver.open(&server, .{ .transport = .tcp, .password = server.password }, &refusal));
}

test "a multi-statement query reports each statement, matched rows and every value kind" {
    var server: Server = try .init();
    defer server.deinit();
    const driver = try std.testing.allocator.create(Driver);
    defer std.testing.allocator.destroy(driver);
    try openReady(driver, &server, .{ .transport = .unix_socket, .password = server.password });
    defer driver.close() catch {};

    var transcript = try driver.run(
        "SET SESSION sql_mode = 'STRICT_ALL_TABLES,NO_BACKSLASH_ESCAPES';" ++
            "CREATE TABLE t (id BIGINT PRIMARY KEY, v VARBINARY(16) NOT NULL, n BIGINT NULL);" ++
            "INSERT INTO t VALUES (1, X'6869', NULL), (2, X'', 7);" ++
            "UPDATE t SET n = 7 WHERE id = 2;" ++
            "SELECT id, v, n FROM t ORDER BY id",
    );
    // The UPDATE changes nothing; CLIENT_FOUND_ROWS counts the row it matched.
    try transcript.expect(
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
    );
}

test "a failing statement ends the query, and the statements after it never run" {
    var server: Server = try .init();
    defer server.deinit();
    const driver = try std.testing.allocator.create(Driver);
    defer std.testing.allocator.destroy(driver);
    try openReady(driver, &server, .{ .transport = .unix_socket, .password = server.password });
    defer driver.close() catch {};

    var transcript = try driver.run(
        "INSERT INTO t VALUES (3, X'', NULL); INSERT INTO t VALUES (3, X'', NULL); INSERT INTO t VALUES (4, X'', NULL)",
    );
    try transcript.expect(
        \\ok 1 more
        \\err 1062 23000 Duplicate entry '3' for key 't.PRIMARY'
    );
    transcript = try driver.run("SELECT COUNT(*) FROM t WHERE id = 4");
    try transcript.expect(
        \\columns 1
        \\column COUNT(*) longlong not_null binary
        \\row
        \\value 1 0
        \\rows_end
    );
}

test "OK packets report an open transaction" {
    var server: Server = try .init();
    defer server.deinit();
    const driver = try std.testing.allocator.create(Driver);
    defer std.testing.allocator.destroy(driver);
    try openReady(driver, &server, .{ .transport = .unix_socket, .password = server.password });
    defer driver.close() catch {};

    var transcript = try driver.run("BEGIN; UPDATE t SET n = 1 WHERE id = 1; ROLLBACK");
    try transcript.expect(
        \\ok 0 more in_transaction
        \\ok 1 more in_transaction
        \\ok 0
    );
}

test "a value larger than the receive buffer streams through it" {
    var server: Server = try .init();
    defer server.deinit();
    const driver = try std.testing.allocator.create(Driver);
    defer std.testing.allocator.destroy(driver);
    try openReady(driver, &server, .{ .transport = .unix_socket, .password = server.password });
    defer driver.close() catch {};

    const len = 200_000;
    var transcript = try driver.run(std.fmt.comptimePrint("SELECT REPEAT('x', {d}) AS big", .{len}));
    try std.testing.expect(transcript.chunks > len / mysql.receive_buffer_min);
    defer transcript.deinit();
    const head = "columns 1\ncolumn big medium_blob\nrow\nvalue 200000 ";
    const tail = "\nrows_end";
    const text = transcript.text.written();
    try std.testing.expectEqualStrings(head, text[0..head.len]);
    try std.testing.expectEqualStrings(tail, text[text.len - tail.len ..]);
    const value = text[head.len .. text.len - tail.len];
    try std.testing.expectEqual(len, value.len);
    try std.testing.expectEqual(len, std.mem.count(u8, value, "x"));
}
