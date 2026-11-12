//! The MySQL wire client against a real MySQL 8.4 server, through the
//! Store's blocking connection (src/store/wire/mysql_connection.zig).
//! mysql_wire_integration.py starts the server and passes its socket, port
//! and passwords in the environment; this binary fails rather than skips
//! when they are missing.
//!
//! The server starts with an empty authentication cache, so the first test
//! sees the cold-cache logins before any login fills it. Tests run in
//! declaration order.
const std = @import("std");
const mysql_connection = @import("mysql_connection");
const mysql = mysql_connection.mysql;
const Driver = mysql_connection.Connection;

const Server = struct {
    socket: []const u8,
    port: u16,
    password: []const u8,
    root_password: []const u8,
    /// The certificate the server presents for 127.0.0.1, its own CA.
    ca_file: []const u8,
    environ: std.process.Environ.Map,

    fn init() !Server {
        var environ = try std.testing.environ.createMap(std.testing.allocator);
        errdefer environ.deinit();
        return .{
            .socket = environ.get("RUI_MYSQL_SOCKET") orelse return error.MissingServer,
            .port = try std.fmt.parseInt(u16, environ.get("RUI_MYSQL_PORT") orelse return error.MissingServer, 10),
            .password = environ.get("RUI_MYSQL_PASSWORD") orelse return error.MissingServer,
            .root_password = environ.get("RUI_MYSQL_ROOT_PASSWORD") orelse return error.MissingServer,
            .ca_file = environ.get("RUI_MYSQL_CA_FILE") orelse return error.MissingServer,
            .environ = environ,
        };
    }

    fn deinit(self: *Server) void {
        self.environ.deinit();
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

const Login = struct {
    transport: enum { tcp, tcp_tls, unix_socket },
    user: []const u8 = "rui",
    password: []const u8,
    /// For `.tcp_tls`: the server's own certificate unless set.
    trust: ?mysql_connection.tls.Trust = null,
};

/// Logs in to the database `rui`; a refusal's event goes to `refusal`.
fn open(driver: *Driver, server: *const Server, login: Login, refusal: *std.Io.Writer) !void {
    const address: mysql_connection.Address = switch (login.transport) {
        .unix_socket => .{ .unix_socket = server.socket },
        .tcp => .{ .tcp = .{ .host = "127.0.0.1", .port = server.port } },
        .tcp_tls => .{ .tcp_tls = .{ .host = "127.0.0.1", .port = server.port, .trust = login.trust orelse .{ .ca_file = server.ca_file } } },
    };
    try driver.open(.{ .address = address, .user = login.user, .password = login.password, .database = "rui", .deadline_ms = 30_000 }, refusal);
}

fn openReady(driver: *Driver, server: *const Server, login: Login) !void {
    var refusal: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer refusal.deinit();
    open(driver, server, login, &refusal.writer) catch |err| {
        if (err == error.LoginRefused) std.debug.print("login refused: {s}\n", .{refusal.written()});
        return err;
    };
}

/// Runs `text` and renders every event of its results.
fn run(driver: *Driver, text: []const u8) !Transcript {
    try driver.query(text);
    var transcript: Transcript = .init();
    errdefer transcript.deinit();
    while (!driver.isReady()) try transcript.add(try driver.next());
    return transcript;
}

test "logins: plaintext TCP with a cold cache, the full exchange over a Unix socket, then the cached scramble over TCP" {
    var server: Server = try .init();
    defer server.deinit();
    const driver = try std.testing.allocator.create(Driver);
    defer std.testing.allocator.destroy(driver);
    var refusal: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer refusal.deinit();

    // No login has cached the account's hash, so the server asks for the
    // password itself, which plaintext TCP must not carry.
    try std.testing.expectError(error.AuthMethodRefused, open(driver, &server, .{ .transport = .tcp, .password = server.password }, &refusal.writer));

    try std.testing.expectError(error.LoginRefused, open(driver, &server, .{ .transport = .unix_socket, .password = "not the password" }, &refusal.writer));
    try std.testing.expectStringStartsWith(refusal.written(), "err 1045 28000 Access denied for user 'rui'@'localhost'");

    try openReady(driver, &server, .{ .transport = .unix_socket, .password = server.password });
    driver.close();

    // The Unix socket login cached the hash; the scramble alone now suffices.
    try openReady(driver, &server, .{ .transport = .tcp, .password = server.password });
    var transcript = try run(driver, "SELECT CURRENT_USER()");
    try transcript.expect(
        \\columns 1
        \\column CURRENT_USER() var_string
        \\row
        \\value 5 rui@%
        \\rows_end
    );
    driver.close();

    // FLUSH PRIVILEGES empties the cache, so plaintext TCP is refused again.
    try openReady(driver, &server, .{ .transport = .unix_socket, .user = "root", .password = server.root_password });
    transcript = try run(driver, "FLUSH PRIVILEGES");
    try transcript.expect("ok 0");
    driver.close();
    try std.testing.expectError(error.AuthMethodRefused, open(driver, &server, .{ .transport = .tcp, .password = server.password }, &refusal.writer));
}

test "a multi-statement query reports each statement, matched rows and every value kind" {
    var server: Server = try .init();
    defer server.deinit();
    const driver = try std.testing.allocator.create(Driver);
    defer std.testing.allocator.destroy(driver);
    try openReady(driver, &server, .{ .transport = .unix_socket, .password = server.password });

    var transcript = try run(
        driver,
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
    driver.close();
}

test "a failing statement ends the query, and the statements after it never run" {
    var server: Server = try .init();
    defer server.deinit();
    const driver = try std.testing.allocator.create(Driver);
    defer std.testing.allocator.destroy(driver);
    try openReady(driver, &server, .{ .transport = .unix_socket, .password = server.password });

    var transcript = try run(
        driver,
        "INSERT INTO t VALUES (3, X'', NULL); INSERT INTO t VALUES (3, X'', NULL); INSERT INTO t VALUES (4, X'', NULL)",
    );
    try transcript.expect(
        \\ok 1 more
        \\err 1062 23000 Duplicate entry '3' for key 't.PRIMARY'
    );
    transcript = try run(driver, "SELECT COUNT(*) FROM t WHERE id = 4");
    try transcript.expect(
        \\columns 1
        \\column COUNT(*) longlong not_null binary
        \\row
        \\value 1 0
        \\rows_end
    );
    driver.close();
}

test "OK packets report an open transaction" {
    var server: Server = try .init();
    defer server.deinit();
    const driver = try std.testing.allocator.create(Driver);
    defer std.testing.allocator.destroy(driver);
    try openReady(driver, &server, .{ .transport = .unix_socket, .password = server.password });

    var transcript = try run(driver, "BEGIN; UPDATE t SET n = 1 WHERE id = 1; ROLLBACK");
    try transcript.expect(
        \\ok 0 more in_transaction
        \\ok 1 more in_transaction
        \\ok 0
    );
    driver.close();
}

test "a value larger than the receive buffer streams through it" {
    var server: Server = try .init();
    defer server.deinit();
    const driver = try std.testing.allocator.create(Driver);
    defer std.testing.allocator.destroy(driver);
    try openReady(driver, &server, .{ .transport = .unix_socket, .password = server.password });

    const len = 200_000;
    var transcript = try run(driver, std.fmt.comptimePrint("SELECT REPEAT('x', {d}) AS big", .{len}));
    defer transcript.deinit();
    try std.testing.expect(transcript.chunks > len / mysql.receive_buffer_min);
    const head = "columns 1\ncolumn big medium_blob\nrow\nvalue 200000 ";
    const tail = "\nrows_end";
    const text = transcript.text.written();
    try std.testing.expectEqualStrings(head, text[0..head.len]);
    try std.testing.expectEqualStrings(tail, text[text.len - tail.len ..]);
    const value = text[head.len .. text.len - tail.len];
    try std.testing.expectEqual(len, value.len);
    try std.testing.expectEqual(len, std.mem.count(u8, value, "x"));
    driver.close();
}

test "TCP under TLS verifies the server and carries the full password exchange" {
    var server: Server = try .init();
    defer server.deinit();
    const driver = try std.testing.allocator.create(Driver);
    defer std.testing.allocator.destroy(driver);
    var refusal: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer refusal.deinit();

    // The system's trust does not hold the server's own certificate.
    try std.testing.expectError(error.UntrustedPeer, open(driver, &server, .{ .transport = .tcp_tls, .password = server.password, .trust = .system }, &refusal.writer));

    // FLUSH PRIVILEGES empties the cache, so this login sends the password itself.
    try openReady(driver, &server, .{ .transport = .unix_socket, .user = "root", .password = server.root_password });
    var transcript = try run(driver, "FLUSH PRIVILEGES");
    try transcript.expect("ok 0");
    driver.close();
    try openReady(driver, &server, .{ .transport = .tcp_tls, .password = server.password });
    // SHOW needs no privilege; its column flags are not this test's subject.
    var status = try run(driver, "SHOW SESSION STATUS LIKE 'Ssl_version'");
    defer status.deinit();
    try std.testing.expect(std.mem.indexOf(u8, status.text.written(), "\nrow\nvalue 11 Ssl_version\nvalue 7 TLSv1.") != null);
    driver.close();
}
