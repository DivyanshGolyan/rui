//! MySQL classic client protocol for MySQL 8.4 LTS and later: handshake v10,
//! caching_sha2_password, COM_QUERY with multiple statements, text result
//! sets. MariaDB and MySQL before 8.4 are refused.
//!
//! The client owns no socket, thread or buffer. Its driver reads bytes into a
//! buffer of its own and hands them to `read`, which consumes what it can and
//! returns at most one `Event`; bytes the client wants sent go into the
//! driver's `out` buffer. Who drives the connection, and whether TLS wraps it,
//! is the driver's business, so one client serves a blocking test driver and
//! an event loop alike.
//!
//! Packets other than result rows are decoded whole, so the receive buffer
//! must hold `receive_buffer_min` bytes. A row streams: each value arrives as
//! `.value` (its length) followed by `.bytes` slices, so a row of up to the
//! single-packet limit (16 MiB) passes through a fixed buffer. Slices in
//! events borrow the driver's input and stay valid until the driver discards
//! the bytes they cover.
//!
//! Session settings are the driver's: the handshake can only name
//! utf8mb4_0900_ai_ci (a collation id fits one byte there), so the driver sets
//! utf8mb4_0900_bin and the strict sql_mode with NO_BACKSLASH_ESCAPES by
//! query, and can confirm the latter through `Status.no_backslash_escapes`.
//! Which transports to offer is also the driver's policy; the client only
//! refuses to send the password where it could be read.
//!
//! A command payload of 0xFFFFFF bytes or more would need a continuation
//! packet. Rui's statements stay far below that (16 KiB batches, 128 KiB
//! content chunks rendered as hex), so `query` refuses one rather than split it,
//! and a received packet of that size is refused as a protocol violation.
const std = @import("std");

/// The smallest receive buffer the driver may use: it holds any packet
/// other than a result row.
pub const receive_buffer_min = 16 * 1024;
/// The smallest `out` buffer `read` may be given: it holds any handshake
/// packet for options within the limits below.
pub const send_buffer_min = 2048;

/// MySQL caps user names at 32 characters and schema names at 64; four bytes
/// per character bounds both. No MySQL limit applies to the password; this
/// one keeps every handshake packet within `send_buffer_min`.
pub const max_user_bytes = 32 * 4;
pub const max_database_bytes = 64 * 4;
pub const max_password_bytes = 1024;

/// How the driver reaches the server. The full caching_sha2_password
/// exchange sends the password itself, so only a Unix socket or TLS may
/// carry it.
pub const Transport = enum {
    /// The driver starts TLS on `.start_tls`, before the client sends any
    /// credential.
    tcp_tls,
    /// TCP without TLS: only a cached-scramble login can succeed.
    tcp,
    unix_socket,

    fn secure(transport: Transport) bool {
        return transport != .tcp;
    }
};

/// Borrowed until `read` returns `.ready` or the client closes; the client
/// keeps no copy.
pub const Options = struct {
    user: []const u8,
    password: []const u8,
    database: []const u8,
    transport: Transport,
};

pub const Event = union(enum) {
    /// Send `out[0..n]` before calling `read` again.
    send: usize,
    /// Send `out[0..n]` (the SSLRequest) in plaintext, complete the TLS
    /// handshake, and carry every later byte over TLS. The next `read` emits
    /// the handshake response.
    start_tls: usize,
    /// Logged in; `query` may be called.
    ready,
    /// One statement completed without a result set. With CLIENT_FOUND_ROWS,
    /// `affected_rows` counts matched rows.
    ok: Ok,
    /// The server refused the statement or the login. No further result of
    /// the same query follows: MySQL stops a multi-statement query at its
    /// first error. A login error closes the client.
    err: ServerError,
    /// A result set begins with this many columns; that many `.column`
    /// events follow, then its rows.
    columns: u16,
    column: Column,
    /// A row begins; one `.value` per column follows.
    row,
    /// The next value of the row: null for SQL NULL, else its length in
    /// bytes, delivered by `.bytes` events that add up to it.
    value: ?u32,
    bytes: []const u8,
    /// The result set ended.
    rows_end: Status,

    /// One line for logs and test transcripts; `.bytes` shows only its length.
    pub fn format(event: Event, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (event) {
            .send => |n| try w.print("send {d}", .{n}),
            .start_tls => |n| try w.print("start_tls {d}", .{n}),
            .ready => try w.writeAll("ready"),
            .ok => |ok| {
                try w.print("ok {d}", .{ok.affected_rows});
                try ok.status.format(w);
            },
            .err => |err| try w.print("err {d} {s} {s}", .{ err.code, &err.sql_state, err.message }),
            .columns => |n| try w.print("columns {d}", .{n}),
            .column => |column| {
                try w.print("column {s} ", .{column.name});
                if (std.enums.tagName(ColumnType, column.type)) |name|
                    try w.writeAll(name)
                else
                    try w.print("type{d}", .{@backingInt(column.type)});
                if (column.flags.not_null) try w.writeAll(" not_null");
                if (column.flags.unsigned) try w.writeAll(" unsigned");
                if (column.flags.binary) try w.writeAll(" binary");
            },
            .row => try w.writeAll("row"),
            .value => |len| if (len) |n| try w.print("value {d}", .{n}) else try w.writeAll("null"),
            .bytes => |bytes| try w.print("bytes {d}", .{bytes.len}),
            .rows_end => |status| {
                try w.writeAll("rows_end");
                try status.format(w);
            },
        }
    }
};

pub const Ok = struct {
    affected_rows: u64,
    status: Status,
};

/// SERVER_STATUS flags of an OK packet.
pub const Status = packed struct(u16) {
    in_transaction: bool,
    autocommit: bool,
    _unused: bool,
    /// Another statement's result of the same query follows.
    more_results: bool,
    _index_and_cursor: u5,
    no_backslash_escapes: bool,
    _rest: u6,

    fn format(status: Status, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (status.more_results) try w.writeAll(" more");
        if (status.in_transaction) try w.writeAll(" in_transaction");
        if (status.no_backslash_escapes) try w.writeAll(" no_backslash_escapes");
    }
};

pub const ServerError = struct {
    code: u16,
    sql_state: [5]u8,
    message: []const u8,
};

pub const Column = struct {
    name: []const u8,
    type: ColumnType,
    flags: ColumnFlags,
    charset: u16,
};

pub const ColumnType = enum(u8) {
    decimal = 0,
    tiny = 1,
    short = 2,
    long = 3,
    float = 4,
    double = 5,
    null = 6,
    timestamp = 7,
    longlong = 8,
    int24 = 9,
    date = 10,
    time = 11,
    datetime = 12,
    year = 13,
    varchar = 15,
    bit = 16,
    json = 245,
    newdecimal = 246,
    @"enum" = 247,
    set = 248,
    tiny_blob = 249,
    medium_blob = 250,
    long_blob = 251,
    blob = 252,
    var_string = 253,
    string = 254,
    geometry = 255,
    _,
};

pub const ColumnFlags = packed struct(u16) {
    not_null: bool,
    _keys_and_blob: u4,
    unsigned: bool,
    _zerofill: bool,
    binary: bool,
    _rest: u8,
};

pub const Step = struct {
    consumed: usize,
    event: ?Event,

    /// More input is needed.
    const more: Step = .{ .consumed = 0, .event = null };
};

pub const Error = error{
    /// Bytes the protocol does not allow at this point.
    ProtocolViolation,
    /// A packet other than a row larger than `receive_buffer_min` allows.
    PacketTooLarge,
    /// MariaDB, MySQL before 8.4, or a server lacking a required capability.
    UnsupportedServer,
    /// `.tcp_tls` was asked for and the server does not offer TLS.
    TlsRefused,
    /// The server asked for an authentication method other than
    /// caching_sha2_password, or for the password over plaintext TCP.
    AuthMethodRefused,
};

pub const OptionsError = error{InvalidOptions};

pub const QueryError = error{StatementTooLarge};

const max_payload = 0xFFFFFF - 1;
const max_control_payload = receive_buffer_min - header_len;
const header_len = 4;
const nonce_len = 20;
const max_packet_size: u32 = 1 << 24;
const charset_utf8mb4_0900_ai_ci = 255;
const plugin = "caching_sha2_password";

const Capability = struct {
    const found_rows: u32 = 1 << 1;
    const connect_with_db: u32 = 1 << 3;
    const protocol_41: u32 = 1 << 9;
    const ssl: u32 = 1 << 11;
    const transactions: u32 = 1 << 13;
    const secure_connection: u32 = 1 << 15;
    const multi_statements: u32 = 1 << 16;
    const multi_results: u32 = 1 << 17;
    const plugin_auth: u32 = 1 << 19;
    const plugin_auth_lenenc_client_data: u32 = 1 << 21;
    const deprecate_eof: u32 = 1 << 24;

    /// Everything the client asks for apart from SSL; the server must offer
    /// all of it. Never asked: LOCAL_FILES (lets a server read client files),
    /// INTERACTIVE (selects interactive_timeout), COMPRESS, SESSION_TRACK and
    /// OPTIONAL_RESULTSET_METADATA (column definitions are how a caller
    /// checks result types).
    const required = found_rows | connect_with_db | protocol_41 | transactions | secure_connection |
        multi_statements | multi_results | plugin_auth | plugin_auth_lenenc_client_data | deprecate_eof;
};

const State = union(enum) {
    greeting,
    /// The SSLRequest went out; the next `read` sends the handshake response.
    tls,
    auth: Auth,

    ready,
    /// A query went out; its next statement's first packet is due.
    result,
    columns: u16,
    rows,
    row: Row,
    closed,

    const Auth = enum {
        /// The handshake response's scramble went out.
        scramble_sent,
        /// An AuthSwitchRequest's scramble went out; no second switch follows.
        switched,
        password_sent,
    };

    const Row = struct {
        columns_left: u16,
        packet_left: u32,
        /// Bytes still due of the value being delivered; 0 between values.
        value_left: u32,
    };
};

pub const Client = struct {
    options: Options,
    state: State = .greeting,
    /// The sequence id of the next packet either side sends.
    sequence: u8 = 0,
    nonce: [nonce_len]u8 = undefined,
    column_count: u16 = 0,
    /// The server's id for this connection, for KILL QUERY from another
    /// connection. Set by the greeting.
    connection_id: u32 = 0,

    pub fn init(options: Options) OptionsError!Client {
        if (options.user.len == 0 or options.user.len > max_user_bytes or
            options.database.len == 0 or options.database.len > max_database_bytes or
            options.password.len > max_password_bytes) return error.InvalidOptions;
        // Each is NUL-terminated on the wire.
        for ([_][]const u8{ options.user, options.database, options.password }) |text|
            if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidOptions;
        return .{ .options = options };
    }

    pub fn isReady(self: *const Client) bool {
        return self.state == .ready;
    }

    /// Consumes a prefix of `in` and returns at most one event. A step with
    /// no event and nothing consumed needs more input than `in` holds. After
    /// an error the client is unusable and the driver closes the connection.
    pub fn read(self: *Client, in: []const u8, out: []u8) Error!Step {
        std.debug.assert(out.len >= send_buffer_min);
        return switch (self.state) {
            .greeting => self.readGreeting(in, out),
            .tls => .{ .consumed = 0, .event = .{ .send = self.writeResponse(out) } },
            .auth => self.readAuth(in, out),
            .result => self.readResult(in),
            .columns => self.readColumn(in),
            .rows => self.readRowStart(in),
            .row => |row| self.readRow(in, row),
            .ready, .closed => unreachable,
        };
    }

    /// The 5-byte prefix of a COM_QUERY whose statement text is `text_len`
    /// bytes. The driver sends the prefix, then exactly that text.
    pub fn query(self: *Client, text_len: usize) QueryError![5]u8 {
        std.debug.assert(self.state == .ready);
        if (text_len + 1 > max_payload) return error.StatementTooLarge;
        var prefix: [5]u8 = undefined;
        writeHeader(prefix[0..4], @intCast(text_len + 1), 0);
        prefix[4] = 0x03;
        self.sequence = 1;
        self.state = .result;
        return prefix;
    }

    /// COM_QUIT, after which the driver closes the connection.
    pub fn quit(self: *Client) [5]u8 {
        std.debug.assert(self.state == .ready);
        self.state = .closed;
        return .{ 1, 0, 0, 0, 0x01 };
    }

    fn readGreeting(self: *Client, in: []const u8, out: []u8) Error!Step {
        const payload = try self.packet(in) orelse return .more;
        const consumed = header_len + payload.len;
        if (payload.len > 0 and payload[0] == 0xFF) {
            self.state = .closed;
            return .{ .consumed = consumed, .event = .{ .err = try parseErr(payload) } };
        }
        var cursor: Cursor = .{ .bytes = payload };
        if (try cursor.int(u8) != 10) return error.UnsupportedServer;
        try checkVersion(try cursor.nulString());
        self.connection_id = try cursor.int(u32);
        const nonce_head = try cursor.take(8);
        _ = try cursor.int(u8);
        var capabilities: u32 = try cursor.int(u16);
        _ = try cursor.int(u8); // charset
        _ = try cursor.int(u16); // status
        capabilities |= @as(u32, try cursor.int(u16)) << 16;
        const auth_data_len = try cursor.int(u8);
        _ = try cursor.take(10);
        if (capabilities & Capability.required != Capability.required) return error.UnsupportedServer;
        // Part two holds the nonce's last 12 bytes and a NUL.
        if (auth_data_len != nonce_len + 1) return error.ProtocolViolation;
        const nonce_tail = try cursor.take(nonce_len - 8 + 1);
        if (nonce_tail[nonce_len - 8] != 0) return error.ProtocolViolation;
        self.nonce[0..8].* = nonce_head[0..8].*;
        self.nonce[8..].* = nonce_tail[0 .. nonce_len - 8].*;
        // The server's default plugin needs no check: the response names
        // caching_sha2_password, and a server that wants another switches.
        _ = try cursor.nulString();

        if (self.options.transport != .tcp_tls) {
            self.state = .{ .auth = .scramble_sent };
            return .{ .consumed = consumed, .event = .{ .send = self.writeResponse(out) } };
        }
        if (capabilities & Capability.ssl == 0) return error.TlsRefused;
        var writer: PacketWriter = .start(out, self.nextSequence());
        self.writeLoginPrefix(&writer);
        self.state = .tls;
        return .{ .consumed = consumed, .event = .{ .start_tls = writer.finish() } };
    }

    /// The 32 bytes an SSLRequest consists of and a HandshakeResponse41
    /// starts with.
    fn writeLoginPrefix(self: *const Client, writer: *PacketWriter) void {
        writer.int(u32, Capability.required | if (self.options.transport == .tcp_tls) Capability.ssl else 0);
        writer.int(u32, max_packet_size);
        writer.int(u8, charset_utf8mb4_0900_ai_ci);
        writer.zeros(23);
    }

    /// HandshakeResponse41.
    fn writeResponse(self: *Client, out: []u8) usize {
        var writer: PacketWriter = .start(out, self.nextSequence());
        self.writeLoginPrefix(&writer);
        writer.nulString(self.options.user);
        if (self.options.password.len == 0) {
            writer.int(u8, 0);
        } else {
            writer.int(u8, 32);
            writer.bytes(&scramble(self.options.password, &self.nonce));
        }
        writer.nulString(self.options.database);
        writer.nulString(plugin);
        self.state = .{ .auth = .scramble_sent };
        return writer.finish();
    }

    fn readAuth(self: *Client, in: []const u8, out: []u8) Error!Step {
        const payload = try self.packet(in) orelse return .more;
        const consumed = header_len + payload.len;
        switch (payload[0]) {
            0x00 => {
                _ = try parseOk(payload);
                self.state = .ready;
                self.options.password = "";
                return .{ .consumed = consumed, .event = .ready };
            },
            0xFF => {
                self.state = .closed;
                return .{ .consumed = consumed, .event = .{ .err = try parseErr(payload) } };
            },
            // AuthMoreData: the scramble matched a cached entry (3), or the
            // server needs the password itself (4).
            0x01 => {
                if (payload.len != 2) return error.ProtocolViolation;
                switch (payload[1]) {
                    3 => {
                        if (self.state.auth == .password_sent) return error.ProtocolViolation;
                        return .{ .consumed = consumed, .event = null };
                    },
                    4 => {
                        if (self.state.auth == .password_sent) return error.ProtocolViolation;
                        if (!self.options.transport.secure()) return error.AuthMethodRefused;
                        var writer: PacketWriter = .start(out, self.nextSequence());
                        writer.nulString(self.options.password);
                        self.state = .{ .auth = .password_sent };
                        return .{ .consumed = consumed, .event = .{ .send = writer.finish() } };
                    },
                    else => return error.ProtocolViolation,
                }
            },
            // AuthSwitchRequest: accepted only for caching_sha2_password with
            // a fresh nonce, which happens when the account's plugin is that
            // and the server's default is not.
            0xFE => {
                if (self.state.auth != .scramble_sent) return error.ProtocolViolation;
                var cursor: Cursor = .{ .bytes = payload[1..] };
                if (!std.mem.eql(u8, try cursor.nulString(), plugin)) return error.AuthMethodRefused;
                const data = cursor.rest();
                if (data.len != nonce_len + 1 or data[nonce_len] != 0) return error.ProtocolViolation;
                self.nonce = data[0..nonce_len].*;
                self.state = .{ .auth = .switched };
                var writer: PacketWriter = .start(out, self.nextSequence());
                if (self.options.password.len != 0) writer.bytes(&scramble(self.options.password, &self.nonce));
                return .{ .consumed = consumed, .event = .{ .send = writer.finish() } };
            },
            else => return error.ProtocolViolation,
        }
    }

    fn readResult(self: *Client, in: []const u8) Error!Step {
        const payload = try self.packet(in) orelse return .more;
        const consumed = header_len + payload.len;
        switch (payload[0]) {
            0x00 => {
                const ok = try parseOk(payload);
                if (!ok.status.more_results) self.state = .ready;
                return .{ .consumed = consumed, .event = .{ .ok = ok } };
            },
            0xFF => {
                self.state = .ready;
                return .{ .consumed = consumed, .event = .{ .err = try parseErr(payload) } };
            },
            // 0xFB asks for a LOCAL INFILE, which the client never enables;
            // 0xFE is never a statement's first packet.
            0xFB, 0xFE => return error.ProtocolViolation,
            else => {
                var cursor: Cursor = .{ .bytes = payload };
                const count = try cursor.lenenc();
                if (cursor.rest().len != 0 or count == 0 or count > std.math.maxInt(u16)) return error.ProtocolViolation;
                self.column_count = @intCast(count);
                self.state = .{ .columns = self.column_count };
                return .{ .consumed = consumed, .event = .{ .columns = self.column_count } };
            },
        }
    }

    fn readColumn(self: *Client, in: []const u8) Error!Step {
        const payload = try self.packet(in) orelse return .more;
        var cursor: Cursor = .{ .bytes = payload };
        for (0..4) |_| _ = try cursor.lenencString(); // catalog, schema, table, org_table
        const name = try cursor.lenencString();
        _ = try cursor.lenencString(); // org_name
        if (try cursor.lenenc() != 0x0c) return error.ProtocolViolation;
        const charset = try cursor.int(u16);
        _ = try cursor.int(u32); // display length
        const column_type: ColumnType = @fromBackingInt(@intCast(try cursor.int(u8)));
        const flags: ColumnFlags = @bitCast(try cursor.int(u16));
        _ = try cursor.take(3); // decimals, filler
        if (cursor.rest().len != 0) return error.ProtocolViolation;
        const left = self.state.columns - 1;
        self.state = if (left == 0) .rows else .{ .columns = left };
        return .{
            .consumed = header_len + payload.len,
            .event = .{ .column = .{ .name = name, .type = column_type, .flags = flags, .charset = charset } },
        };
    }

    fn readRowStart(self: *Client, in: []const u8) Error!Step {
        if (in.len < header_len + 1) return .more;
        _ = try payloadLen(in);
        // A row's first byte is a value's length prefix, never 0xFE (a value
        // of 16 MiB or more) or 0xFF; those open the terminating OK or an ERR.
        switch (in[header_len]) {
            0xFE => {
                const payload = try self.packet(in) orelse return .more;
                const ok = try parseOk(payload);
                self.state = if (ok.status.more_results) .result else .ready;
                return .{ .consumed = header_len + payload.len, .event = .{ .rows_end = ok.status } };
            },
            0xFF => {
                const payload = try self.packet(in) orelse return .more;
                self.state = .ready;
                return .{ .consumed = header_len + payload.len, .event = .{ .err = try parseErr(payload) } };
            },
            else => {
                const len = try self.header(in);
                self.state = .{ .row = .{ .columns_left = self.column_count, .packet_left = len, .value_left = 0 } };
                return .{ .consumed = header_len, .event = .row };
            },
        }
    }

    fn readRow(self: *Client, in: []const u8, row: State.Row) Error!Step {
        var next = row;
        if (row.value_left > 0) {
            const n: u32 = @intCast(@min(in.len, row.value_left));
            if (n == 0) return .more;
            next.value_left -= n;
            next.packet_left -= n;
            try self.advanceRow(next);
            return .{ .consumed = n, .event = .{ .bytes = in[0..n] } };
        }
        if (in.len == 0) return .more;
        const prefix_len: u32 = switch (in[0]) {
            0xFB => {
                next.packet_left = std.math.sub(u32, next.packet_left, 1) catch return error.ProtocolViolation;
                next.columns_left -= 1;
                try self.advanceRow(next);
                return .{ .consumed = 1, .event = .{ .value = null } };
            },
            0xFC => 3,
            0xFD => 4,
            0xFE, 0xFF => return error.ProtocolViolation,
            else => 1,
        };
        if (prefix_len > row.packet_left) return error.ProtocolViolation;
        if (in.len < prefix_len) return .more;
        const len: u32 = switch (prefix_len) {
            1 => in[0],
            3 => std.mem.readInt(u16, in[1..3], .little),
            else => std.mem.readInt(u24, in[1..4], .little),
        };
        next.packet_left -= prefix_len;
        if (len > next.packet_left) return error.ProtocolViolation;
        next.columns_left -= 1;
        next.value_left = len;
        try self.advanceRow(next);
        return .{ .consumed = prefix_len, .event = .{ .value = len } };
    }

    /// Stores the row's progress; after its last value the packet must end.
    fn advanceRow(self: *Client, row: State.Row) Error!void {
        if (row.columns_left == 0 and row.value_left == 0) {
            if (row.packet_left != 0) return error.ProtocolViolation;
            self.state = .rows;
        } else {
            self.state = .{ .row = row };
        }
    }

    /// The payload of the whole packet at the start of `in`, or null if
    /// `in` does not hold all of it yet.
    fn packet(self: *Client, in: []const u8) Error!?[]const u8 {
        if (in.len < header_len) return null;
        const len = try payloadLen(in);
        if (len > max_control_payload) return error.PacketTooLarge;
        if (in.len < header_len + len) return null;
        _ = try self.header(in);
        return in[header_len..][0..len];
    }

    /// Checks the packet header at the start of `in` and returns its length.
    fn header(self: *Client, in: []const u8) Error!u32 {
        const len = try payloadLen(in);
        if (in[3] != self.sequence) return error.ProtocolViolation;
        self.sequence +%= 1;
        return len;
    }

    fn nextSequence(self: *Client) u8 {
        defer self.sequence +%= 1;
        return self.sequence;
    }
};

/// MySQL 8.4 or later. MariaDB reports a 5.5.5- prefixed version and names
/// itself; either way it is refused.
fn checkVersion(version: []const u8) Error!void {
    if (std.mem.indexOf(u8, version, "MariaDB") != null) return error.UnsupportedServer;
    var parts = std.mem.splitScalar(u8, version, '.');
    const major = std.fmt.parseInt(u16, parts.next().?, 10) catch return error.UnsupportedServer;
    const minor_text = parts.next() orelse return error.UnsupportedServer;
    const minor = std.fmt.parseInt(u16, minor_text, 10) catch return error.UnsupportedServer;
    if (major < 8 or (major == 8 and minor < 4)) return error.UnsupportedServer;
}

/// caching_sha2_password: SHA256(p) XOR SHA256(SHA256(SHA256(p)) || nonce).
fn scramble(password: []const u8, nonce: *const [nonce_len]u8) [32]u8 {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var digest: [32]u8 = undefined;
    Sha256.hash(password, &digest, .{});
    var double: [32]u8 = undefined;
    Sha256.hash(&digest, &double, .{});
    var mixed: [32]u8 = undefined;
    var hash: Sha256 = .init(.{});
    hash.update(&double);
    hash.update(nonce);
    hash.final(&mixed);
    for (&digest, mixed) |*byte, mask| byte.* ^= mask;
    std.crypto.secureZero(u8, &double);
    return digest;
}

fn parseOk(payload: []const u8) Error!Ok {
    var cursor: Cursor = .{ .bytes = payload[1..] };
    const affected_rows = try cursor.lenenc();
    _ = try cursor.lenenc(); // last insert id
    const status: Status = @bitCast(try cursor.int(u16));
    _ = try cursor.int(u16); // warnings
    return .{ .affected_rows = affected_rows, .status = status };
}

fn parseErr(payload: []const u8) Error!ServerError {
    var cursor: Cursor = .{ .bytes = payload[1..] };
    const code = try cursor.int(u16);
    var sql_state: [5]u8 = "HY000".*;
    // A server refusing the connection before the handshake sends no state.
    if (payload.len >= 9 and payload[3] == '#') sql_state = (try cursor.take(6))[1..6].*;
    return .{ .code = code, .sql_state = sql_state, .message = cursor.rest() };
}

/// The length in the packet header at the start of `in`. No packet the
/// server sends on these paths is empty, and none needs a continuation.
fn payloadLen(in: []const u8) Error!u32 {
    const len = std.mem.readInt(u24, in[0..3], .little);
    if (len == 0 or len > max_payload) return error.ProtocolViolation;
    return len;
}

fn writeHeader(out: *[4]u8, len: u24, sequence: u8) void {
    std.mem.writeInt(u24, out[0..3], len, .little);
    out[3] = sequence;
}

/// Reads a whole packet's payload; reading past its end is a protocol
/// violation.
const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Cursor, n: usize) Error![]const u8 {
        if (self.bytes.len - self.pos < n) return error.ProtocolViolation;
        defer self.pos += n;
        return self.bytes[self.pos..][0..n];
    }

    fn int(self: *Cursor, comptime T: type) Error!T {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        return std.mem.readInt(T, (try self.take(n))[0..n], .little);
    }

    fn lenenc(self: *Cursor) Error!u64 {
        const first = try self.int(u8);
        return switch (first) {
            0xFC => try self.int(u16),
            0xFD => try self.int(u24),
            0xFE => try self.int(u64),
            0xFB, 0xFF => error.ProtocolViolation,
            else => first,
        };
    }

    fn lenencString(self: *Cursor) Error![]const u8 {
        const len = try self.lenenc();
        if (len > self.bytes.len) return error.ProtocolViolation;
        return self.take(@intCast(len));
    }

    fn nulString(self: *Cursor) Error![]const u8 {
        const end = std.mem.indexOfScalarPos(u8, self.bytes, self.pos, 0) orelse return error.ProtocolViolation;
        defer self.pos = end + 1;
        return self.bytes[self.pos..end];
    }

    fn rest(self: *Cursor) []const u8 {
        defer self.pos = self.bytes.len;
        return self.bytes[self.pos..];
    }
};

/// Writes one packet into the driver's `out`, whose size `read` checked
/// against every packet the options allow.
const PacketWriter = struct {
    out: []u8,
    len: usize = header_len,
    sequence: u8,

    fn start(out: []u8, sequence: u8) PacketWriter {
        return .{ .out = out, .sequence = sequence };
    }

    fn bytes(self: *PacketWriter, data: []const u8) void {
        @memcpy(self.out[self.len..][0..data.len], data);
        self.len += data.len;
    }

    fn int(self: *PacketWriter, comptime T: type, value: T) void {
        std.mem.writeInt(T, self.out[self.len..][0..@sizeOf(T)], value, .little);
        self.len += @sizeOf(T);
    }

    fn zeros(self: *PacketWriter, n: usize) void {
        @memset(self.out[self.len..][0..n], 0);
        self.len += n;
    }

    fn nulString(self: *PacketWriter, text: []const u8) void {
        self.bytes(text);
        self.int(u8, 0);
    }

    fn finish(self: *PacketWriter) usize {
        writeHeader(self.out[0..4], @intCast(self.len - header_len), self.sequence);
        return self.len;
    }
};

/// One connection's bytes as a real MySQL 8.4.13 exchanged them with this
/// client, recorded by a proxy between the two, in order.
const Capture = struct {
    transport: Transport,
    user: []const u8 = "rui",
    password: []const u8,
    chunks: []const struct { enum { server, client }, []const u8 },
};

fn hex(comptime text: []const u8) *const [text.len / 2]u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var bytes: [text.len / 2]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, text) catch unreachable;
        const final = bytes;
        return &final;
    }
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

    fn add(self: *Transcript, event: Event) !void {
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

    fn line(self: *Transcript, text: []const u8) !void {
        if (self.text.written().len > 0) try self.text.writer.writeByte('\n');
        try self.text.writer.writeAll(text);
    }
};

/// Replays `capture`, handing the client the server's bytes `split` at a
/// time. Each byte the client sends must equal the recorded one; the client
/// runs each recorded query or quit when it is next. Returns the events, and
/// the error that ended the replay as its last line.
fn replay(capture: Capture, split: usize) !Transcript {
    var transcript: Transcript = .init();
    errdefer transcript.deinit();
    var client: Client = try .init(.{ .user = capture.user, .password = capture.password, .database = "rui", .transport = capture.transport });
    var in_buffer: [4096]u8 = undefined;
    var in: []u8 = in_buffer[0..0];
    var out: [send_buffer_min]u8 = undefined;
    var start: usize = 0;
    var chunk: usize = 0;
    while (chunk < capture.chunks.len) {
        const direction, const bytes = capture.chunks[chunk];
        chunk += 1;
        switch (direction) {
            .client => {
                // Only a query or a quit is the driver's to start.
                try std.testing.expect(client.isReady());
                if (std.mem.eql(u8, bytes, &.{ 1, 0, 0, 0, 1 })) {
                    try std.testing.expectEqualSlices(u8, bytes, &client.quit());
                } else {
                    try std.testing.expectEqualSlices(u8, bytes[0..5], &try client.query(bytes.len - 5));
                }
                continue;
            },
            .server => {},
        }
        var fed: usize = 0;
        while (fed < bytes.len) {
            const n = @min(split, bytes.len - fed);
            @memcpy(in_buffer[in.len..][0..n], bytes[fed..][0..n]);
            in = in_buffer[0 .. in.len + n];
            fed += n;
            while (!client.isReady() and client.state != .closed) {
                const step = client.read(in[start..], &out) catch |err| {
                    try transcript.line(@errorName(err));
                    return transcript;
                };
                start += step.consumed;
                const event = step.event orelse if (step.consumed == 0) break else continue;
                try transcript.add(event);
                switch (event) {
                    .send, .start_tls => |len| {
                        try std.testing.expect(chunk < capture.chunks.len);
                        const sent_direction, const sent = capture.chunks[chunk];
                        chunk += 1;
                        try std.testing.expectEqual(.client, sent_direction);
                        try std.testing.expectEqualSlices(u8, sent, out[0..len]);
                    },
                    else => {},
                }
            }
        }
    }
    // Every byte the server sent was read.
    try std.testing.expectEqual(in.len, start);
    return transcript;
}

/// Replays `capture` at every split, from one byte at a time to whole
/// chunks, and expects the same transcript from each.
fn expectReplay(capture: Capture, expected: []const u8) !void {
    var largest: usize = 0;
    for (capture.chunks) |chunk| largest = @max(largest, chunk[1].len);
    for (1..largest + 1) |split| {
        var transcript = try replay(capture, split);
        defer transcript.deinit();
        try std.testing.expectEqualStrings(expected, transcript.text.written());
    }
}

test "a cold authentication cache refuses the login over plaintext TCP before the password is sent" {
    try expectReplay(cold_cache_tcp,
        \\send 99
        \\AuthMethodRefused
    );
}

test "the full exchange sends the password over a Unix socket and reports the server's refusal" {
    try expectReplay(wrong_password_unix,
        \\send 99
        \\send 21
        \\err 1045 28000 Access denied for user 'rui'@'localhost' (using password: YES)
    );
}

test "a cached scramble logs in over TCP, and a query reads its result set" {
    try expectReplay(cached_tcp,
        \\send 99
        \\ready
        \\columns 1
        \\column CURRENT_USER() var_string
        \\row
        \\value 5 rui@%
        \\rows_end
    );
}

test "a multi-statement query reports each statement's result in order" {
    try expectReplay(multi_statement,
        \\send 99
        \\send 37
        \\ready
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

test "a statement's error ends its query" {
    try expectReplay(error_stops,
        \\send 99
        \\ready
        \\ok 1 more
        \\err 1062 23000 Duplicate entry '3' for key 't.PRIMARY'
        \\columns 1
        \\column COUNT(*) longlong not_null binary
        \\row
        \\value 1 0
        \\rows_end
    );
}

test "OK packets carry the open transaction" {
    try expectReplay(transaction,
        \\send 99
        \\ready
        \\ok 0 more in_transaction
        \\ok 1 more in_transaction
        \\ok 0
    );
}

test "the scramble matches an independent caching_sha2_password computation" {
    // Python: m1 = sha256(p); m3 = sha256(sha256(m1) + nonce); m1 XOR m3.
    var nonce: [nonce_len]u8 = undefined;
    for (&nonce, 1..) |*byte, i| byte.* = @intCast(i);
    try std.testing.expectEqualSlices(u8, comptime hex("746ebe205d56a0707acb3e796e834e0dd7b1d61743b26bd5202c7a623230c7c9"), &scramble("secret", &nonce));
}

const greeting = cached_tcp.chunks[0][1];

const plain_options: Options = .{ .user = "rui", .password = "pw", .database = "rui", .transport = .tcp };
const tls_options: Options = .{ .user = "rui", .password = "pw", .database = "rui", .transport = .tcp_tls };

fn readOne(client: *Client, in: []const u8) Error!Step {
    var out: [send_buffer_min]u8 = undefined;
    return client.read(in, &out);
}

test "TLS: the SSLRequest goes first, and the handshake response follows it after the TLS handshake" {
    var client: Client = try .init(tls_options);
    var out: [send_buffer_min]u8 = undefined;
    const first = try client.read(greeting, &out);
    try std.testing.expectEqual(greeting.len, first.consumed);
    const request_len = first.event.?.start_tls;
    try std.testing.expectEqual(4 + 32, request_len);
    const request = out[0 .. 4 + 32].*;
    try std.testing.expectEqual(1, request[3]);
    try std.testing.expect(std.mem.readInt(u32, request[4..8], .little) & Capability.ssl != 0);
    const second = try client.read("", &out);
    try std.testing.expectEqual(0, second.consumed);
    const response = out[0..second.event.?.send];
    try std.testing.expectEqual(2, response[3]);
    // The response repeats the request's capabilities, packet size and charset.
    try std.testing.expectEqualSlices(u8, request[4..], response[4..36]);
}

test "TLS is refused by a server that does not offer it" {
    var edited = greeting[0..greeting.len].*;
    // The capability's low half follows the version, connection id and nonce head.
    const at = 4 + 1 + std.mem.indexOfScalar(u8, edited[5..], 0).? + 1 + 4 + 8 + 1;
    edited[at + 1] &= ~@as(u8, Capability.ssl >> 8);
    var client: Client = try .init(tls_options);
    try std.testing.expectError(error.TlsRefused, readOne(&client, &edited));
    // The same greeting without TLS asked for is accepted.
    var plain: Client = try .init(plain_options);
    _ = try readOne(&plain, &edited);
}

test "MariaDB and MySQL before 8.4 are refused" {
    // MariaDB 11.4.13's greeting.
    const mariadb = comptime hex("5b0000000a31312e342e31332d4d6172696144422d75627532343034000300000050683a2859677c5800feff2d0200ff81150000000000001d000000244821696e6b4f297d5d3a47006d7973716c5f6e61746976655f70617373776f726400");
    var client: Client = try .init(plain_options);
    try std.testing.expectError(error.UnsupportedServer, readOne(&client, mariadb));
    var edited = greeting[0..greeting.len].*;
    try std.testing.expectEqualStrings("8.4.13", edited[5..11]);
    edited[7] = '0';
    client = try .init(plain_options);
    try std.testing.expectError(error.UnsupportedServer, readOne(&client, &edited));
    try checkVersion("9.1.0");
    try checkVersion("8.4.0");
    try std.testing.expectError(error.UnsupportedServer, checkVersion("8.3.0"));
    try std.testing.expectError(error.UnsupportedServer, checkVersion("5.7.44-log"));
}

fn authSwitch(comptime body: []const u8) *const [5 + body.len]u8 {
    return &([_]u8{ body.len + 1, 0, 0, 2, 0xFE } ++ body[0..body.len].*);
}

test "an authentication switch is followed only to caching_sha2_password" {
    var client: Client = try .init(plain_options);
    _ = try readOne(&client, greeting);
    try std.testing.expectError(error.AuthMethodRefused, readOne(&client, authSwitch("mysql_native_password\x00aaaaaaaaaaaaaaaaaaaa\x00")));

    client = try .init(plain_options);
    _ = try readOne(&client, greeting);
    var out: [send_buffer_min]u8 = undefined;
    const fresh = "0123456789abcdefghij";
    const step = try client.read(authSwitch("caching_sha2_password\x00" ++ fresh ++ "\x00"), &out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 32, 0, 0, 3 }, out[0..4]);
    try std.testing.expectEqualSlices(u8, &scramble("pw", fresh), out[4..step.event.?.send]);
}

test "a packet out of sequence is a protocol violation" {
    var edited = greeting[0..greeting.len].*;
    edited[3] = 1;
    var client: Client = try .init(plain_options);
    try std.testing.expectError(error.ProtocolViolation, readOne(&client, &edited));
}

/// A client that has sent a query; the next packet's sequence id is 1.
fn querying() !Client {
    var client: Client = try .init(plain_options);
    client.state = .ready;
    _ = try client.query(1);
    return client;
}

test "an authentication exchange takes each step at most once" {
    const fresh = "0123456789abcdefghij";
    const to_sha2 = authSwitch("caching_sha2_password\x00" ++ fresh ++ "\x00");
    var client: Client = try .init(plain_options);
    _ = try readOne(&client, greeting);
    _ = try readOne(&client, to_sha2);
    // A second switch, with the sequence id it would carry.
    var again = to_sha2.*;
    again[3] = 4;
    try std.testing.expectError(error.ProtocolViolation, readOne(&client, &again));

    var unix: Client = try .init(.{ .user = "rui", .password = "pw", .database = "rui", .transport = .unix_socket });
    _ = try readOne(&unix, greeting);
    _ = try readOne(&unix, "\x02\x00\x00\x02\x01\x04");
    // After the password, only OK or ERR may follow.
    try std.testing.expectError(error.ProtocolViolation, readOne(&unix, "\x02\x00\x00\x04\x01\x03"));
}

test "malformed results are refused" {
    // An empty packet where a row may start, followed by bytes that would
    // read as an ERR's first byte.
    var empty_row = try querying();
    empty_row.column_count = 1;
    empty_row.state = .rows;
    try std.testing.expectError(error.ProtocolViolation, readOne(&empty_row, "\x00\x00\x00\x01\xff\x00\x00\x02"));
    // An empty packet where a statement's result is due.
    var empty_result = try querying();
    try std.testing.expectError(error.ProtocolViolation, readOne(&empty_result, "\x00\x00\x00\x01"));
    // A LOCAL INFILE request, which the client never enables.
    var client = try querying();
    try std.testing.expectError(error.ProtocolViolation, readOne(&client, "\x05\x00\x00\x01\xfbfile"));
    // A non-row packet larger than the receive buffer.
    client = try querying();
    try std.testing.expectError(error.PacketTooLarge, readOne(&client, &std.mem.toBytes(@as(u32, max_control_payload + 1) | 1 << 24)));
    // A row whose value runs past its packet.
    client = try querying();
    client.column_count = 1;
    client.state = .rows;
    try std.testing.expectEqual(Event.row, (try readOne(&client, "\x02\x00\x00\x01\x05ab")).event.?);
    try std.testing.expectError(error.ProtocolViolation, readOne(&client, "\x05ab"));
    // A row with bytes after its last value.
    client = try querying();
    client.column_count = 1;
    client.state = .rows;
    _ = try readOne(&client, "\x03\x00\x00\x01\x01ab");
    try std.testing.expectEqual(@as(?u32, 1), (try readOne(&client, "\x01ab")).event.?.value);
    try std.testing.expectError(error.ProtocolViolation, readOne(&client, "ab"));
}

test "a query that needs a continuation packet is refused" {
    var client: Client = try .init(plain_options);
    client.state = .ready;
    try std.testing.expectError(error.StatementTooLarge, client.query(max_payload));
    try std.testing.expectEqualSlices(u8, &.{ 0xFE, 0xFF, 0xFF, 0, 3 }, &try client.query(max_payload - 1));
}

test "options that cannot cross the wire are refused" {
    const valid = plain_options;
    _ = try Client.init(valid);
    var options = valid;
    options.user = "r\x00ui";
    try std.testing.expectError(error.InvalidOptions, Client.init(options));
    options = valid;
    options.database = "";
    try std.testing.expectError(error.InvalidOptions, Client.init(options));
    options = valid;
    options.password = &@as([max_password_bytes + 1]u8, @splat('p'));
    try std.testing.expectError(error.InvalidOptions, Client.init(options));
}

const cold_cache_tcp: Capture = .{
    .transport = .tcp,
    .password = "2eb44bf811303c6a65647341debc2afc",
    .chunks = &.{
        .{ .server, hex("4a0000000a382e342e31330008000000756f010f5b063e0500ffffff0200ffdf1500000000000000000000510d4954045a0374594652310063616368696e675f736861325f70617373776f726400") },
        .{ .client, hex("5f0000010aa22b0100000001ff0000000000000000000000000000000000000000000000727569002078a1912d08c022a53612c2f0a09862819c582b3c3ebf18a367a7f96b105340257275690063616368696e675f736861325f70617373776f726400") },
        .{ .server, hex("020000020104") },
        .{ .server, hex("33000003ff8604233038533031476f7420616e206572726f722072656164696e6720636f6d6d756e69636174696f6e207061636b657473") },
    },
};

const wrong_password_unix: Capture = .{
    .transport = .unix_socket,
    .password = "not the password",
    .chunks = &.{
        .{ .server, hex("4a0000000a382e342e313300090000005d74142c16232c7600ffffff0200ffdf15000000000000000000000b6d4331653e137743205a010063616368696e675f736861325f70617373776f726400") },
        .{ .client, hex("5f0000010aa22b0100000001ff00000000000000000000000000000000000000000000007275690020034cfe28e0ed8eb93ffda1079f2d658d51660e12d8bb469a9e1b5ae0885499ce7275690063616368696e675f736861325f70617373776f726400") },
        .{ .server, hex("020000020104") },
        .{ .client, hex("110000036e6f74207468652070617373776f726400") },
        .{ .server, hex("47000004ff15042332383030304163636573732064656e69656420666f72207573657220277275692740276c6f63616c686f73742720287573696e672070617373776f72643a2059455329") },
    },
};

const cached_tcp: Capture = .{
    .transport = .tcp,
    .password = "2eb44bf811303c6a65647341debc2afc",
    .chunks = &.{
        .{ .server, hex("4a0000000a382e342e3133000b000000707b484b7941282700ffffff0200ffdf15000000000000000000005d524949356c2a3b3c082c690063616368696e675f736861325f70617373776f726400") },
        .{ .client, hex("5f0000010aa22b0100000001ff000000000000000000000000000000000000000000000072756900208260317366b9dafca8be6660ee581e0dfc982129abb114d18d57afebce2648327275690063616368696e675f736861325f70617373776f726400") },
        .{ .server, hex("0200000201030700000300000002000000") },
        .{ .client, hex("160000000353454c4543542043555252454e545f555345522829") },
        .{ .server, hex("010000010124000002036465660000000e43555252454e545f555345522829000cff0080040000fd00001f00000600000305727569402507000004fe000002000000") },
        .{ .client, hex("0100000001") },
    },
};

const multi_statement: Capture = .{
    .transport = .unix_socket,
    .password = "2eb44bf811303c6a65647341debc2afc",
    .chunks = &.{
        .{ .server, hex("4a0000000a382e342e3133000e0000005c63307b3a39013d00ffffff0200ffdf150000000000000000000071500a051906267e7e133c5b0063616368696e675f736861325f70617373776f726400") },
        .{ .client, hex("5f0000010aa22b0100000001ff00000000000000000000000000000000000000000000007275690020715ec1979ce9997fca9c7a522bce7f873861d4016677c72bc0caefb1dac1f6ef7275690063616368696e675f736861325f70617373776f726400") },
        .{ .server, hex("020000020104") },
        .{ .client, hex("21000003326562343462663831313330336336613635363437333431646562633261666300") },
        .{ .server, hex("0700000400000002000000") },
        .{ .client, hex("08010000035345542053455353494f4e2073716c5f6d6f6465203d20275354524943545f414c4c5f5441424c45532c4e4f5f4241434b534c4153485f45534341504553273b435245415445205441424c4520742028696420424947494e54205052494d415259204b45592c20762056415242494e41525928313629204e4f54204e554c4c2c206e20424947494e54204e554c4c293b494e5345525420494e544f20742056414c5545532028312c20582736383639272c204e554c4c292c2028322c205827272c2037293b555044415445207420534554206e203d2037205748455245206964203d20323b53454c4543542069642c20762c206e2046524f4d2074204f52444552204259206964") },
        .{ .server, hex("070000010000000a020100") },
        .{ .server, hex("070000020000000a020000") },
        .{ .server, hex("2e0000030002000a020000265265636f7264733a203220204475706c6963617465733a203020205761726e696e67733a2030") },
        .{ .server, hex("300000040001000a02000028526f7773206d6174636865643a203120204368616e6765643a203020205761726e696e67733a2030") },
        .{ .server, hex("01000005031f0000060364656603727569017401740269640269640c3f00140000000803500000001d000007036465660372756901740174017601760c3f0010000000fd81100000001d000008036465660372756901740174016e016e0c3f0014000000080000000000060000090131026869fb0500000a01320001370700000bfe000002020000") },
        .{ .client, hex("0100000001") },
    },
};

const error_stops: Capture = .{
    .transport = .unix_socket,
    .password = "2eb44bf811303c6a65647341debc2afc",
    .chunks = &.{
        .{ .server, hex("4a0000000a382e342e3133000f000000110a1b26676b120100ffffff0200ffdf1500000000000000000000554a74331b530e36411876560063616368696e675f736861325f70617373776f726400") },
        .{ .client, hex("5f0000010aa22b0100000001ff000000000000000000000000000000000000000000000072756900209bec913ebc189f5e238c40ea9f75908b52d6ac29f1c69c61e91d9d79903d20ed7275690063616368696e675f736861325f70617373776f726400") },
        .{ .server, hex("020000020103") },
        .{ .server, hex("0700000300000002000000") },
        .{ .client, hex("6e00000003494e5345525420494e544f20742056414c5545532028332c205827272c204e554c4c293b20494e5345525420494e544f20742056414c5545532028332c205827272c204e554c4c293b20494e5345525420494e544f20742056414c5545532028342c205827272c204e554c4c29") },
        .{ .server, hex("070000010001000a000000") },
        .{ .server, hex("30000002ff26042332333030304475706c696361746520656e7472792027332720666f72206b65792027742e5052494d41525927") },
        .{ .client, hex("240000000353454c45435420434f554e54282a292046524f4d2074205748455245206964203d2034") },
        .{ .server, hex("01000001011e0000020364656600000008434f554e54282a29000c3f001500000008810000000002000003013007000004fe000002000000") },
        .{ .client, hex("0100000001") },
    },
};

const transaction: Capture = .{
    .transport = .unix_socket,
    .password = "2eb44bf811303c6a65647341debc2afc",
    .chunks = &.{
        .{ .server, hex("4a0000000a382e342e31330010000000107643261530222f00ffffff0200ffdf1500000000000000000000052d6875622e5f345768066d0063616368696e675f736861325f70617373776f726400") },
        .{ .client, hex("5f0000010aa22b0100000001ff00000000000000000000000000000000000000000000007275690020b92cc520b7830465d7bfe9e90a2f9d06198a70798368828ac36d66073a5542db7275690063616368696e675f736861325f70617373776f726400") },
        .{ .server, hex("020000020103") },
        .{ .server, hex("0700000300000002000000") },
        .{ .client, hex("3100000003424547494e3b20555044415445207420534554206e203d2031205748455245206964203d20313b20524f4c4c4241434b") },
        .{ .server, hex("070000010000000b000000") },
        .{ .server, hex("300000020001000b00000028526f7773206d6174636865643a203120204368616e6765643a203120205761726e696e67733a2030") },
        .{ .server, hex("0700000300000002000000") },
        .{ .client, hex("0100000001") },
    },
};
