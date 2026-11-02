//! Postgres frontend/backend protocol 3.0 for the Store's Postgres engine:
//! startup over TLS with SCRAM-SHA-256(-PLUS), and the extended-query
//! messages a pipelined round needs.
//!
//! No I/O. Encoders append to the caller's `Outbox`, the `Decoder` reads
//! the caller's received bytes, and `Startup` is the connection's state
//! machine up to its first ReadyForQuery. Whoever owns the socket moves
//! the bytes; `tls.zig` encrypts them between caller buffers the same way.
//!
//! Memory: nothing allocates. A connection needs one `send_buffer_bytes`
//! outbox and one `receive_buffer_bytes` inbox. A column value too long
//! for the inbox arrives in parts (`Event.value_begin`), and a bound value
//! too long for the outbox is written through it (`beginBindStreamed`).
const std = @import("std");
const scram = @import("scram.zig");

pub const tls = @import("tls.zig");

pub const send_buffer_bytes = 16 * 1024;
pub const receive_buffer_bytes = 16 * 1024;
/// A column value up to this length arrives whole in one `Event.value`.
pub const max_inline_value_bytes = receive_buffer_bytes - 4;
/// Every backend message other than DataRow, ErrorResponse and
/// NoticeResponse must fit the inbox whole.
pub const max_message_bytes = receive_buffer_bytes;

/// PG 15 is the oldest release the Store supports.
pub const minimum_server_major: u32 = 15;

const protocol_version: u32 = 3 << 16;
const ssl_request_code: u32 = 80877103;
const format_binary: u16 = 1;

// ------------------------------------------------------------ encoding

pub const Outbox = struct {
    buffer: []u8,
    len: usize = 0,

    pub fn bytes(self: *const Outbox) []const u8 {
        return self.buffer[0..self.len];
    }

    /// Drops the first `count` bytes, after the owner sent them.
    pub fn discard(self: *Outbox, count: usize) void {
        std.debug.assert(count <= self.len);
        std.mem.copyForwards(u8, self.buffer, self.buffer[count..self.len]);
        self.len -= count;
    }

    pub fn free(self: *const Outbox) usize {
        return self.buffer.len - self.len;
    }

    /// Appends as much of `data` as fits and returns how much did: the body
    /// of a value started by `beginBindStreamed`.
    pub fn appendPart(self: *Outbox, data: []const u8) usize {
        const count = @min(data.len, self.free());
        @memcpy(self.buffer[self.len..][0..count], data[0..count]);
        self.len += count;
        return count;
    }

    fn put(self: *Outbox, data: []const u8) void {
        @memcpy(self.buffer[self.len..][0..data.len], data);
        self.len += data.len;
    }

    fn putInt(self: *Outbox, comptime T: type, value: T) void {
        std.mem.writeInt(T, self.buffer[self.len..][0..@sizeOf(T)], value, .big);
        self.len += @sizeOf(T);
    }

    fn putString(self: *Outbox, text: []const u8) void {
        self.put(text);
        self.put(&.{0});
    }

    /// Starts a message whose whole length is `body_len` after its length
    /// word, failing with nothing written when the part written now
    /// (`now_len` bytes of body) does not fit.
    fn begin(self: *Outbox, tag: ?u8, body_len: usize, now_len: usize) error{NoSpace}!void {
        const head: usize = if (tag == null) 4 else 5;
        if (self.free() < head + now_len) return error.NoSpace;
        if (tag) |t| self.put(&.{t});
        self.putInt(u32, @intCast(4 + body_len));
    }
};

pub const EncodeError = error{NoSpace};

/// A startup string must hold no NUL; this checks one from outside Rui.
pub fn validString(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, 0) == null;
}

pub fn writeSslRequest(out: *Outbox) EncodeError!void {
    try out.begin(null, 4, 4);
    out.putInt(u32, ssl_request_code);
}

/// `settings` are run-time parameters set for the session (GUCs).
pub fn writeStartup(out: *Outbox, user: []const u8, database: []const u8, settings: []const [2][]const u8) EncodeError!void {
    var body: usize = 4 + "user".len + 1 + user.len + 1 + "database".len + 1 + database.len + 1 + 1;
    for (settings) |pair| body += pair[0].len + 1 + pair[1].len + 1;
    try out.begin(null, body, body);
    out.putInt(u32, protocol_version);
    out.putString("user");
    out.putString(user);
    out.putString("database");
    out.putString(database);
    for (settings) |pair| {
        out.putString(pair[0]);
        out.putString(pair[1]);
    }
    out.put(&.{0});
}

pub fn writeSaslInitial(out: *Outbox, mechanism: []const u8, data: []const u8) EncodeError!void {
    const body = mechanism.len + 1 + 4 + data.len;
    try out.begin('p', body, body);
    out.putString(mechanism);
    out.putInt(u32, @intCast(data.len));
    out.put(data);
}

pub fn writeSaslResponse(out: *Outbox, data: []const u8) EncodeError!void {
    try out.begin('p', data.len, data.len);
    out.put(data);
}

/// A simple Query: several statements in one string, text results.
pub fn writeQuery(out: *Outbox, sql: []const u8) EncodeError!void {
    std.debug.assert(validString(sql));
    const body = sql.len + 1;
    try out.begin('Q', body, body);
    out.putString(sql);
}

/// Parse into the named prepared statement. `param_oids` may leave types
/// for the server to infer with 0.
pub fn writeParse(out: *Outbox, name: []const u8, sql: []const u8, param_oids: []const u32) EncodeError!void {
    std.debug.assert(validString(name) and validString(sql));
    const body = name.len + 1 + sql.len + 1 + 2 + 4 * param_oids.len;
    try out.begin('P', body, body);
    out.putString(name);
    out.putString(sql);
    out.putInt(u16, @intCast(param_oids.len));
    for (param_oids) |oid| out.putInt(u32, oid);
}

/// Describe a prepared statement: ParameterDescription, then
/// RowDescription or NoData.
pub fn writeDescribeStatement(out: *Outbox, name: []const u8) EncodeError!void {
    const body = 1 + name.len + 1;
    try out.begin('D', body, body);
    out.put("S");
    out.putString(name);
}

/// Bind the unnamed portal to `statement`, every parameter and result in
/// binary format. A null parameter is SQL NULL.
pub fn writeBind(out: *Outbox, statement: []const u8, params: []const ?[]const u8) EncodeError!void {
    const body = bindHeadLen(statement, params) + 4;
    try out.begin('B', body, body);
    putBindHead(out, statement, params, params.len);
    putResultFormats(out);
}

/// Bind whose last parameter, `streamed_len` bytes long, follows through
/// `Outbox.appendPart` and is closed by `endBindStreamed`.
pub fn beginBindStreamed(out: *Outbox, statement: []const u8, params: []const ?[]const u8, streamed_len: u32) EncodeError!void {
    const head = bindHeadLen(statement, params) + 4;
    try out.begin('B', head + streamed_len + 4, head);
    putBindHead(out, statement, params, params.len + 1);
    out.putInt(u32, streamed_len);
}

pub fn endBindStreamed(out: *Outbox) EncodeError!void {
    if (out.free() < 4) return error.NoSpace;
    putResultFormats(out);
}

fn bindHeadLen(statement: []const u8, params: []const ?[]const u8) usize {
    var len: usize = 1 + statement.len + 1 + 2 + 2 + 2;
    for (params) |param| len += 4 + if (param) |value| value.len else 0;
    return len;
}

fn putBindHead(out: *Outbox, statement: []const u8, params: []const ?[]const u8, count: usize) void {
    std.debug.assert(validString(statement));
    out.putString("");
    out.putString(statement);
    out.putInt(u16, 1);
    out.putInt(u16, format_binary);
    out.putInt(u16, @intCast(count));
    for (params) |param| {
        if (param) |value| {
            out.putInt(u32, @intCast(value.len));
            out.put(value);
        } else out.putInt(i32, -1);
    }
}

fn putResultFormats(out: *Outbox) void {
    out.putInt(u16, 1);
    out.putInt(u16, format_binary);
}

/// Execute the unnamed portal to completion. Statements bound their own
/// row counts, so there is no row limit and no PortalSuspended.
pub fn writeExecute(out: *Outbox) EncodeError!void {
    try out.begin('E', 5, 5);
    out.putString("");
    out.putInt(u32, 0);
}

pub fn writeSync(out: *Outbox) EncodeError!void {
    try out.begin('S', 0, 0);
}

pub fn writeTerminate(out: *Outbox) EncodeError!void {
    try out.begin('X', 0, 0);
}

// ------------------------------------------------------------ decoding

pub const DecodeError = error{ProtocolViolation};

pub const TransactionStatus = enum(u8) { idle = 'I', in_transaction = 'T', failed = 'E' };

pub const Authentication = union(enum) {
    ok,
    /// The mechanisms offered, as the message lists them.
    sasl: Strings,
    sasl_continue: []const u8,
    sasl_final: []const u8,
    /// Any other request (cleartext, MD5, GSS, SSPI); Rui refuses them.
    other: u32,
};

/// A list of NUL-terminated strings ended by an empty one.
pub const Strings = struct {
    body: []const u8,

    pub fn contains(self: Strings, wanted: []const u8) bool {
        var items = std.mem.splitScalar(u8, self.body, 0);
        while (items.next()) |item| {
            if (item.len == 0) return false;
            if (std.mem.eql(u8, item, wanted)) return true;
        }
        return false;
    }
};

pub const RowDescription = struct {
    columns: u16,
    body: []const u8,

    pub const Field = struct { name: []const u8, type_oid: u32, format: u16 };

    pub fn iterator(self: RowDescription) Iterator {
        return .{ .reader = .{ .bytes = self.body } };
    }

    pub const Iterator = struct {
        reader: Reader,

        pub fn next(self: *Iterator) ?Field {
            if (self.reader.bytes.len == 0) return null;
            const name = self.reader.string() catch unreachable;
            self.reader.skip(6) catch unreachable;
            const oid = self.reader.int(u32) catch unreachable;
            self.reader.skip(6) catch unreachable;
            const format = self.reader.int(u16) catch unreachable;
            return .{ .name = name, .type_oid = oid, .format = format };
        }
    };
};

pub const ParameterDescription = struct {
    oids: []const u8,

    pub fn count(self: ParameterDescription) usize {
        return self.oids.len / 4;
    }

    pub fn oid(self: ParameterDescription, index: usize) u32 {
        return std.mem.readInt(u32, self.oids[index * 4 ..][0..4], .big);
    }
};

pub const CommandComplete = struct {
    tag: []const u8,

    /// The row count that ends INSERT, UPDATE, DELETE, SELECT, MERGE,
    /// MOVE, FETCH and COPY tags; null for any other command.
    pub fn rows(self: CommandComplete) ?u64 {
        const space = std.mem.lastIndexOfScalar(u8, self.tag, ' ') orelse return null;
        return std.fmt.parseUnsigned(u64, self.tag[space + 1 ..], 10) catch null;
    }
};

/// Messages read whole. Slices point into the caller's input and live
/// until it discards the consumed bytes.
pub const Message = union(enum) {
    authentication: Authentication,
    parameter_status: struct { name: []const u8, value: []const u8 },
    backend_key_data: struct { pid: u32, key: u32 },
    ready_for_query: TransactionStatus,
    parse_complete,
    bind_complete,
    no_data,
    parameter_description: ParameterDescription,
    row_description: RowDescription,
    command_complete: CommandComplete,
    empty_query,
};

pub const Event = union(enum) {
    message: Message,
    /// A DataRow starts; this many column events follow.
    row: u16,
    /// A whole column: null for SQL NULL.
    value: ?[]const u8,
    /// A column of this many bytes, longer than `max_inline_value_bytes`;
    /// `value_part` events carry exactly that many bytes in order.
    value_begin: u32,
    value_part: []const u8,
    error_response: Diagnostic,
};

pub const Decoded = struct {
    consumed: usize,
    /// Null: the event needs bytes not received yet. Keep the unconsumed
    /// bytes at the start of a `receive_buffer_bytes` inbox and read more.
    event: ?Event,
};

pub const Severity = enum { err, fatal, panic, other };

/// What Rui keeps of an ErrorResponse. Fields read past these sizes are
/// dropped, so a long message cannot grow it.
pub const Diagnostic = struct {
    sqlstate: [5]u8 = @splat('0'),
    severity_buffer: [5]u8 = undefined,
    severity_len: u8 = 0,
    message_buffer: [128]u8 = undefined,
    message_len: u8 = 0,

    pub fn message(self: *const Diagnostic) []const u8 {
        return self.message_buffer[0..self.message_len];
    }

    /// From the non-localized severity field.
    pub fn severity(self: *const Diagnostic) Severity {
        const text = self.severity_buffer[0..self.severity_len];
        if (std.mem.eql(u8, text, "ERROR")) return .err;
        if (std.mem.eql(u8, text, "FATAL")) return .fatal;
        if (std.mem.eql(u8, text, "PANIC")) return .panic;
        return .other;
    }

    pub fn class(self: *const Diagnostic) Class {
        return classify(self.sqlstate);
    }
};

/// A streaming decoder of backend messages after startup's SSL answer.
pub const Decoder = struct {
    state: State = .header,
    /// Bytes left in the current DataRow or field message.
    left: u32 = 0,
    columns_left: u16 = 0,
    value_left: u32 = 0,
    fields: Fields = .{},

    const State = enum { header, row, value, fields };

    const Fields = struct {
        notice: bool = false,
        code: ?u8 = null,
        terminated: bool = false,
        /// Bytes of the current field's value seen so far.
        seen: usize = 0,
        diagnostic: Diagnostic = .{},

        fn feed(self: *Fields, bytes: []const u8, last: bool) DecodeError!void {
            var index: usize = 0;
            while (index < bytes.len) {
                const code = self.code orelse {
                    const byte = bytes[index];
                    index += 1;
                    if (byte == 0) {
                        if (!last or index != bytes.len) return error.ProtocolViolation;
                        self.terminated = true;
                        return;
                    }
                    self.code = byte;
                    self.seen = 0;
                    continue;
                };
                const end = std.mem.indexOfScalarPos(u8, bytes, index, 0);
                const part = bytes[index .. end orelse bytes.len];
                keepField(&self.diagnostic, code, self.seen, part);
                self.seen += part.len;
                if (end) |nul| {
                    index = nul + 1;
                    self.code = null;
                } else index = bytes.len;
            }
        }
    };

    pub fn next(self: *Decoder, input: []const u8) DecodeError!Decoded {
        var at: usize = 0;
        while (true) {
            const rest = input[at..];
            switch (self.state) {
                .header => {
                    if (rest.len < 5) return .{ .consumed = at, .event = null };
                    const tag = rest[0];
                    const length = std.mem.readInt(u32, rest[1..5], .big);
                    if (length < 4 or length > std.math.maxInt(i32)) return error.ProtocolViolation;
                    const body_len = length - 4;
                    switch (tag) {
                        'D' => {
                            if (rest.len < 7) return .{ .consumed = at, .event = null };
                            if (body_len < 2) return error.ProtocolViolation;
                            self.state = .row;
                            self.left = body_len - 2;
                            self.columns_left = std.mem.readInt(u16, rest[5..7], .big);
                            return .{ .consumed = at + 7, .event = .{ .row = self.columns_left } };
                        },
                        'E', 'N' => {
                            self.state = .fields;
                            self.left = body_len;
                            self.fields = .{ .notice = tag == 'N' };
                            at += 5;
                        },
                        else => {
                            if (body_len > max_message_bytes - 5) return error.ProtocolViolation;
                            if (rest.len < 5 + body_len) return .{ .consumed = at, .event = null };
                            const message = try parseMessage(tag, rest[5..][0..body_len]);
                            return .{ .consumed = at + 5 + body_len, .event = .{ .message = message } };
                        },
                    }
                },
                .row => {
                    if (self.columns_left == 0) {
                        if (self.left != 0) return error.ProtocolViolation;
                        self.state = .header;
                        continue;
                    }
                    if (rest.len < 4) return .{ .consumed = at, .event = null };
                    if (self.left < 4) return error.ProtocolViolation;
                    const length = std.mem.readInt(i32, rest[0..4], .big);
                    if (length == -1) {
                        self.left -= 4;
                        self.columns_left -= 1;
                        return .{ .consumed = at + 4, .event = .{ .value = null } };
                    }
                    if (length < 0 or length > self.left - 4) return error.ProtocolViolation;
                    const len: u32 = @intCast(length);
                    if (len <= max_inline_value_bytes) {
                        if (rest.len < 4 + len) return .{ .consumed = at, .event = null };
                        self.left -= 4 + len;
                        self.columns_left -= 1;
                        return .{ .consumed = at + 4 + len, .event = .{ .value = rest[4..][0..len] } };
                    }
                    self.left -= 4 + len;
                    self.columns_left -= 1;
                    self.value_left = len;
                    self.state = .value;
                    return .{ .consumed = at + 4, .event = .{ .value_begin = len } };
                },
                .value => {
                    if (self.value_left == 0) {
                        self.state = .row;
                        continue;
                    }
                    if (rest.len == 0) return .{ .consumed = at, .event = null };
                    const count = @min(rest.len, self.value_left);
                    self.value_left -= @intCast(count);
                    return .{ .consumed = at + count, .event = .{ .value_part = rest[0..count] } };
                },
                .fields => {
                    if (self.left == 0) {
                        if (!self.fields.terminated) return error.ProtocolViolation;
                        self.state = .header;
                        if (self.fields.notice) continue;
                        return .{ .consumed = at, .event = .{ .error_response = self.fields.diagnostic } };
                    }
                    if (rest.len == 0) return .{ .consumed = at, .event = null };
                    const count = @min(rest.len, self.left);
                    try self.fields.feed(rest[0..count], self.left == count);
                    self.left -= @intCast(count);
                    at += count;
                },
            }
        }
    }
};

/// Keeps the fields Rui reads: SQLSTATE, the non-localized severity, and
/// the start of the primary message.
fn keepField(diagnostic: *Diagnostic, code: u8, offset: usize, part: []const u8) void {
    switch (code) {
        'C' => for (part, offset..) |byte, at| {
            if (at < 5) diagnostic.sqlstate[at] = byte;
        },
        'V' => for (part, offset..) |byte, at| {
            if (at >= diagnostic.severity_buffer.len) {
                diagnostic.severity_len = 0;
                break;
            }
            diagnostic.severity_buffer[at] = byte;
            diagnostic.severity_len = @intCast(at + 1);
        },
        'M' => {
            const room = diagnostic.message_buffer.len - diagnostic.message_len;
            const count = @min(room, part.len);
            @memcpy(diagnostic.message_buffer[diagnostic.message_len..][0..count], part[0..count]);
            diagnostic.message_len += @intCast(count);
        },
        else => {},
    }
}

const Reader = struct {
    bytes: []const u8,

    fn int(self: *Reader, comptime T: type) DecodeError!T {
        if (self.bytes.len < @sizeOf(T)) return error.ProtocolViolation;
        const value = std.mem.readInt(T, self.bytes[0..@sizeOf(T)], .big);
        self.bytes = self.bytes[@sizeOf(T)..];
        return value;
    }

    fn string(self: *Reader) DecodeError![]const u8 {
        const nul = std.mem.indexOfScalar(u8, self.bytes, 0) orelse return error.ProtocolViolation;
        const text = self.bytes[0..nul];
        self.bytes = self.bytes[nul + 1 ..];
        return text;
    }

    fn skip(self: *Reader, count: usize) DecodeError!void {
        if (self.bytes.len < count) return error.ProtocolViolation;
        self.bytes = self.bytes[count..];
    }

    fn end(self: *const Reader) DecodeError!void {
        if (self.bytes.len != 0) return error.ProtocolViolation;
    }
};

fn parseMessage(tag: u8, body: []const u8) DecodeError!Message {
    var reader: Reader = .{ .bytes = body };
    const message: Message = switch (tag) {
        'R' => .{ .authentication = switch (try reader.int(u32)) {
            0 => .ok,
            10 => sasl: {
                const list = reader.bytes;
                if (list.len < 2 or list[list.len - 1] != 0 or list[list.len - 2] != 0) return error.ProtocolViolation;
                reader.bytes = &.{};
                break :sasl .{ .sasl = .{ .body = list } };
            },
            11 => rest: {
                defer reader.bytes = &.{};
                break :rest .{ .sasl_continue = reader.bytes };
            },
            12 => rest: {
                defer reader.bytes = &.{};
                break :rest .{ .sasl_final = reader.bytes };
            },
            else => |code| other: {
                reader.bytes = &.{};
                break :other .{ .other = code };
            },
        } },
        'S' => .{ .parameter_status = .{ .name = try reader.string(), .value = try reader.string() } },
        'K' => .{ .backend_key_data = .{ .pid = try reader.int(u32), .key = try reader.int(u32) } },
        'Z' => .{ .ready_for_query = switch (try reader.int(u8)) {
            'I' => .idle,
            'T' => .in_transaction,
            'E' => .failed,
            else => return error.ProtocolViolation,
        } },
        '1' => .parse_complete,
        '2' => .bind_complete,
        'n' => .no_data,
        'I' => .empty_query,
        't' => description: {
            const count = try reader.int(u16);
            const oids = reader.bytes;
            if (oids.len != @as(usize, count) * 4) return error.ProtocolViolation;
            reader.bytes = &.{};
            break :description .{ .parameter_description = .{ .oids = oids } };
        },
        'T' => description: {
            const columns = try reader.int(u16);
            const fields = reader.bytes;
            for (0..columns) |_| {
                _ = try reader.string();
                try reader.skip(18);
            }
            break :description .{ .row_description = .{ .columns = columns, .body = fields } };
        },
        'C' => .{ .command_complete = .{ .tag = try reader.string() } },
        else => return error.ProtocolViolation,
    };
    try reader.end();
    return message;
}

// ------------------------------------------------------------ errors

/// What an ErrorResponse means for the Store, from its SQLSTATE class.
pub const Class = enum {
    /// Class 08: the connection is gone or unusable.
    connection,
    /// 57P01-57P03, class 53: the server is shutting down, starting up,
    /// or out of resources.
    unavailable,
    /// Class 28: the credential was refused.
    authentication,
    /// 3D000: the database does not exist.
    missing_database,
    /// 57014 (statement_timeout) and 55P03 (lock_timeout).
    timeout,
    /// 40001 and 40P01.
    serialization,
    /// Class 23.
    constraint,
    /// 25006: a read-only transaction or a hot standby.
    read_only,
    /// RUI01: a Store guard raised by the server-side `rui_expect`.
    guard,
    /// Class 42 and 0A: a statement the server will never accept.
    statement,
    /// Classes 58 and XX.
    server_fault,
    other,
};

pub fn classify(sqlstate: [5]u8) Class {
    const exact = [_]struct { [5]u8, Class }{
        .{ "57P01".*, .unavailable },
        .{ "57P02".*, .unavailable },
        .{ "57P03".*, .unavailable },
        .{ "3D000".*, .missing_database },
        .{ "57014".*, .timeout },
        .{ "55P03".*, .timeout },
        .{ "40001".*, .serialization },
        .{ "40P01".*, .serialization },
        .{ "25006".*, .read_only },
        .{ "RUI01".*, .guard },
    };
    for (exact) |entry| if (std.mem.eql(u8, &entry[0], &sqlstate)) return entry[1];
    const classes = [_]struct { [2]u8, Class }{
        .{ "08".*, .connection },
        .{ "53".*, .unavailable },
        .{ "28".*, .authentication },
        .{ "23".*, .constraint },
        .{ "42".*, .statement },
        .{ "0A".*, .statement },
        .{ "58".*, .server_fault },
        .{ "XX".*, .server_fault },
    };
    for (classes) |entry| if (std.mem.eql(u8, &entry[0], sqlstate[0..2])) return entry[1];
    return .other;
}

// ------------------------------------------------------------ startup

pub const Security = enum {
    /// SSLRequest first, then the TLS handshake, then SCRAM, with channel
    /// binding when the server offers it. The only way over TCP.
    tls,
    /// A Unix socket: no TLS, and any method but cleartext or MD5.
    local,
};

pub const Options = struct {
    user: []const u8,
    database: []const u8,
    /// Printable ASCII: SASLprep is the identity on it, so no Unicode
    /// tables are needed to match the server's hash.
    password: []const u8,
    security: Security,
    settings: []const [2][]const u8 = &.{},
    /// Random bytes from the caller: the SCRAM client nonce.
    nonce: [scram.nonce_seed_bytes]u8,
};

pub const StartupError = EncodeError || DecodeError || scram.Error || error{
    TlsRefused,
    AuthMethodRefused,
    /// The server answered with an ErrorResponse; see `Startup.diagnostic`.
    ServerRefused,
    UnsupportedServerVersion,
    UnsupportedServerEncoding,
    UnsupportedServerSetting,
};

/// What the owner does after `Startup.receive`. Bytes in the outbox are
/// always sent first.
pub const Next = enum {
    /// Read more bytes and call `receive` again.
    read,
    /// Run the TLS handshake, then call `tlsReady`. No byte after the
    /// server's answer may have arrived in plaintext.
    start_tls,
    /// Startup is over: the session is idle and accepts queries.
    ready,
};

pub const Step = struct { consumed: usize, next: Next };

/// One connection's startup: `begin`, then `receive` until `.ready`.
pub const Startup = struct {
    options: Options,
    phase: Phase = .initial,
    decoder: Decoder = .{},
    scram: scram.Client = undefined,
    diagnostic: Diagnostic = .{},
    params: Parameters = .{},
    backend: struct { pid: u32 = 0, key: u32 = 0 } = .{},
    channel_binding: ?tls.ChannelBinding = null,

    const Phase = enum { initial, ssl_requested, tls_handshake, startup_sent, sasl_first_sent, sasl_final_sent, authenticated, ready };

    pub const Parameters = struct {
        server_major: u32 = 0,
        server_minor: u32 = 0,
        server_encoding_utf8: bool = false,
        client_encoding_utf8: bool = false,
        integer_datetimes: bool = false,
        standard_conforming_strings: bool = false,

        fn record(self: *Parameters, name: []const u8, value: []const u8) void {
            if (equals(name, "server_version")) {
                // "15.4", "16.15 (Ubuntu 16.15-0ubuntu0.24.04.1)", "17beta1".
                const digits = std.mem.indexOfNone(u8, value, "0123456789") orelse value.len;
                self.server_major = std.fmt.parseUnsigned(u32, value[0..digits], 10) catch 0;
                if (digits < value.len and value[digits] == '.') {
                    const rest = value[digits + 1 ..];
                    const minor_digits = std.mem.indexOfNone(u8, rest, "0123456789") orelse rest.len;
                    self.server_minor = std.fmt.parseUnsigned(u32, rest[0..minor_digits], 10) catch 0;
                } else self.server_minor = 0;
            } else if (equals(name, "server_encoding")) {
                self.server_encoding_utf8 = equals(value, "UTF8");
            } else if (equals(name, "client_encoding")) {
                self.client_encoding_utf8 = equals(value, "UTF8");
            } else if (equals(name, "integer_datetimes")) {
                self.integer_datetimes = equals(value, "on");
            } else if (equals(name, "standard_conforming_strings")) {
                self.standard_conforming_strings = equals(value, "on");
            }
        }

        fn check(self: *const Parameters) StartupError!void {
            if (self.server_major < minimum_server_major) return error.UnsupportedServerVersion;
            // SQL_ASCII would store bytes the Store's text checks assume are UTF-8.
            if (!self.server_encoding_utf8) return error.UnsupportedServerEncoding;
            if (!self.client_encoding_utf8 or !self.integer_datetimes or !self.standard_conforming_strings)
                return error.UnsupportedServerSetting;
        }
    };

    pub fn init(options: Options) StartupError!Startup {
        if (!validString(options.user) or !validString(options.database)) return error.ProtocolViolation;
        for (options.settings) |pair| if (!validString(pair[0]) or !validString(pair[1])) return error.ProtocolViolation;
        try scram.checkPassword(options.password);
        return .{ .options = options };
    }

    pub fn begin(self: *Startup, out: *Outbox) StartupError!void {
        std.debug.assert(self.phase == .initial);
        switch (self.options.security) {
            .tls => {
                try writeSslRequest(out);
                self.phase = .ssl_requested;
            },
            .local => try self.sendStartup(out),
        }
    }

    /// After a verified handshake. `binding` is the server certificate's
    /// tls-server-end-point hash, when it has one.
    pub fn tlsReady(self: *Startup, binding: ?tls.ChannelBinding, out: *Outbox) StartupError!void {
        std.debug.assert(self.phase == .tls_handshake);
        self.channel_binding = binding;
        try self.sendStartup(out);
    }

    fn sendStartup(self: *Startup, out: *Outbox) StartupError!void {
        try writeStartup(out, self.options.user, self.options.database, self.options.settings);
        self.phase = .startup_sent;
    }

    pub fn receive(self: *Startup, input: []const u8, out: *Outbox) StartupError!Step {
        if (self.phase == .ssl_requested) {
            if (input.len == 0) return .{ .consumed = 0, .next = .read };
            if (input[0] != 'S') return error.TlsRefused;
            // Bytes behind the answer would be read as if TLS had
            // protected them (CVE-2021-23222).
            if (input.len != 1) return error.ProtocolViolation;
            self.phase = .tls_handshake;
            return .{ .consumed = 1, .next = .start_tls };
        }
        std.debug.assert(self.phase != .initial and self.phase != .tls_handshake and self.phase != .ready);
        var at: usize = 0;
        while (true) {
            const decoded = try self.decoder.next(input[at..]);
            at += decoded.consumed;
            const event = decoded.event orelse return .{ .consumed = at, .next = .read };
            switch (event) {
                .error_response => |diagnostic| {
                    self.diagnostic = diagnostic;
                    return error.ServerRefused;
                },
                .message => |message| if (try self.handle(message, out)) return .{ .consumed = at, .next = .ready },
                else => return error.ProtocolViolation,
            }
        }
    }

    /// True once ReadyForQuery ends startup.
    fn handle(self: *Startup, message: Message, out: *Outbox) StartupError!bool {
        switch (self.phase) {
            .startup_sent => {
                const auth = switch (message) {
                    .authentication => |auth| auth,
                    else => return error.ProtocolViolation,
                };
                switch (auth) {
                    .ok => {
                        if (self.options.security != .local) return error.AuthMethodRefused;
                        self.phase = .authenticated;
                    },
                    .sasl => |mechanisms| try self.startScram(mechanisms, out),
                    .sasl_continue, .sasl_final => return error.ProtocolViolation,
                    .other => return error.AuthMethodRefused,
                }
            },
            .sasl_first_sent => switch (message) {
                .authentication => |auth| switch (auth) {
                    .sasl_continue => |server_first| {
                        var buffer: [scram.max_message_bytes]u8 = undefined;
                        try writeSaslResponse(out, try self.scram.clientFinal(server_first, self.options.password, &buffer));
                        self.phase = .sasl_final_sent;
                    },
                    else => return error.ProtocolViolation,
                },
                else => return error.ProtocolViolation,
            },
            .sasl_final_sent => switch (message) {
                .authentication => |auth| switch (auth) {
                    .sasl_final => |server_final| try self.scram.verifyServerFinal(server_final),
                    .ok => {
                        if (!self.scram.verified) return error.ProtocolViolation;
                        self.phase = .authenticated;
                    },
                    else => return error.ProtocolViolation,
                },
                else => return error.ProtocolViolation,
            },
            .authenticated => switch (message) {
                .parameter_status => |status| self.params.record(status.name, status.value),
                .backend_key_data => |key| self.backend = .{ .pid = key.pid, .key = key.key },
                .ready_for_query => |status| {
                    if (status != .idle) return error.ProtocolViolation;
                    try self.params.check();
                    self.phase = .ready;
                    return true;
                },
                else => return error.ProtocolViolation,
            },
            .initial, .ssl_requested, .tls_handshake, .ready => unreachable,
        }
        return false;
    }

    fn startScram(self: *Startup, mechanisms: Strings, out: *Outbox) StartupError!void {
        const plus = mechanisms.contains("SCRAM-SHA-256-PLUS");
        const plain = mechanisms.contains("SCRAM-SHA-256");
        const binding: scram.Binding = switch (self.options.security) {
            .local => if (plain) .unsupported else return error.AuthMethodRefused,
            .tls => if (plus)
                .{ .server_end_point = self.channel_binding orelse return error.AuthMethodRefused }
            else if (plain)
                .unused
            else
                return error.AuthMethodRefused,
        };
        self.scram = scram.Client.init(self.options.nonce, binding);
        var buffer: [scram.max_message_bytes]u8 = undefined;
        const mechanism = if (binding == .server_end_point) "SCRAM-SHA-256-PLUS" else "SCRAM-SHA-256";
        try writeSaslInitial(out, mechanism, self.scram.clientFirst(&buffer));
        self.phase = .sasl_first_sent;
    }

    pub fn serverVersionNum(self: *const Startup) u32 {
        return self.params.server_major * 10000 + self.params.server_minor;
    }
};

fn equals(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test {
    _ = scram;
    _ = tls;
    _ = @import("tests.zig");
}
