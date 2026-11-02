//! The Postgres wire client's tests: decoding bytes captured from a real
//! server, the startup machine against scripted answers, and live rounds
//! against a server named by RUI_TEST_PG_PORT (CI runs postgres:15).
const std = @import("std");
const pg = @import("pg.zig");
const tls = pg.tls;

fn hex(comptime text: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var digits: []const u8 = "";
        for (text) |char| if (std.ascii.isHex(char)) {
            digits = digits ++ .{char};
        };
        var bytes: [digits.len / 2]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, digits) catch unreachable;
        const final = bytes;
        return &final;
    }
}

/// A local-socket startup answered by Postgres 16 under `trust`: AuthenticationOk,
/// fourteen ParameterStatus messages, BackendKeyData, ReadyForQuery.
const captured_startup = hex(
    \\5200000008000000005300000017696e5f686f745f7374616e646279006f6666005300000019696e74656765725f6461
    \\746574696d6573006f6e00530000001554696d655a6f6e65004574632f55544300530000001b496e74657276616c5374
    \\796c6500706f73746772657300530000001469735f737570657275736572006f6e0053000000216170706c6963617469
    \\6f6e5f6e616d65007275692d6361707475726500530000002664656661756c745f7472616e73616374696f6e5f726561
    \\645f6f6e6c79006f666600530000001a736372616d5f697465726174696f6e7300343039360053000000174461746553
    \\74796c650049534f2c204d44590053000000237374616e646172645f636f6e666f726d696e675f737472696e6773006f
    \\6e00530000002373657373696f6e5f617574686f72697a6174696f6e00706f737467726573005300000019636c69656e
    \\745f656e636f64696e6700555446380053000000397365727665725f76657273696f6e0031362e313520285562756e74
    \\752031362e31352d307562756e7475302e32342e30342e31290053000000197365727665725f656e636f64696e670055
    \\544638004b0000000c000009491e21816c5a0000000549
);

/// One pipelined round answered by Postgres 16: Parse, Describe, Bind and
/// Execute of `SELECT $1::int8 + 1, 'x'::text, NULL::int4` with 41, then
/// Parse, Bind and Execute of `SELECT 1/0`, then Sync.
const captured_round = hex(
    \\3100000004740000000a000100000014540000004f00033f636f6c756d6e3f00000000000000000000140008ffffffff
    \\0000746578740000000000000000000019ffffffffffff0000696e743400000000000000000000170004ffffffff0000
    \\3200000004440000001b000300000008000000000000002a0000000178ffffffff430000000d53454c45435420310031
    \\000000044500000041534552524f5200564552524f5200433232303132004d6469766973696f6e206279207a65726f00
    \\46696e742e63004c3837300052696e743464697600005a0000000549
);

/// Decodes `input` with the inbox discipline a real owner keeps: at most
/// `chunk` new bytes per read, unconsumed bytes moved to the front, and a
/// `receive_buffer_bytes` inbox. Writes one line per event.
fn transcript(input: []const u8, chunk: usize, writer: *std.Io.Writer) !void {
    var inbox: [pg.receive_buffer_bytes]u8 = undefined;
    var start: usize = 0;
    var end: usize = 0;
    var fed: usize = 0;
    var decoder: pg.Decoder = .{};
    while (true) {
        const decoded = try decoder.next(inbox[start..end]);
        start += decoded.consumed;
        if (decoded.event) |event| {
            try describe(event, writer);
            continue;
        }
        if (fed == input.len) break;
        std.mem.copyForwards(u8, &inbox, inbox[start..end]);
        end -= start;
        start = 0;
        const count = @min(chunk, input.len - fed, inbox.len - end);
        try std.testing.expect(count > 0);
        @memcpy(inbox[end..][0..count], input[fed..][0..count]);
        end += count;
        fed += count;
    }
    try std.testing.expectEqual(start, end);
}

fn describe(event: pg.Event, writer: *std.Io.Writer) !void {
    switch (event) {
        .message => |message| switch (message) {
            .parameter_status => |status| try writer.print("parameter {s}={s}\n", .{ status.name, status.value }),
            .ready_for_query => |status| try writer.print("ready {t}\n", .{status}),
            .parameter_description => |params| {
                try writer.writeAll("parameters");
                for (0..params.count()) |index| try writer.print(" {d}", .{params.oid(index)});
                try writer.writeAll("\n");
            },
            .row_description => |row| {
                try writer.print("columns {d}:", .{row.columns});
                var fields = row.iterator();
                while (fields.next()) |field| try writer.print(" {s}/{d}/{d}", .{ field.name, field.type_oid, field.format });
                try writer.writeAll("\n");
            },
            .command_complete => |complete| try writer.print("complete {s} rows {?d}\n", .{ complete.tag, complete.rows() }),
            .backend_key_data => try writer.writeAll("backend key\n"),
            .authentication => |auth| try writer.print("auth {t}\n", .{auth}),
            else => try writer.print("{t}\n", .{message}),
        },
        .row => |columns| try writer.print("row {d}\n", .{columns}),
        .value => |value| if (value) |bytes| try writer.print("value {x}\n", .{bytes}) else try writer.writeAll("value null\n"),
        .value_begin => |len| try writer.print("value of {d}\n", .{len}),
        .value_part => |part| try writer.print("part {d}\n", .{part.len}),
        .error_response => |diagnostic| try writer.print("error {s} {t} {t} {s}\n", .{ diagnostic.sqlstate, diagnostic.severity(), diagnostic.class(), diagnostic.message() }),
    }
}

const expected_round =
    \\parse_complete
    \\parameters 20
    \\columns 3: ?column?/20/0 text/25/0 int4/23/0
    \\bind_complete
    \\row 3
    \\value 000000000000002a
    \\value 78
    \\value null
    \\complete SELECT 1 rows 1
    \\parse_complete
    \\error 22012 err other division by zero
    \\ready idle
    \\
;

test "a captured pipelined round decodes the same whether it arrives whole or a byte at a time" {
    for ([_]usize{ captured_round.len, 1, 7 }) |chunk| {
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try transcript(captured_round, chunk, &output.writer);
        try std.testing.expectEqualStrings(expected_round, output.written());
    }
}

fn dataRow(comptime values: []const ?[]const u8) []const u8 {
    comptime {
        var body: []const u8 = std.mem.toBytes(std.mem.nativeToBig(u16, values.len))[0..];
        for (values) |value| {
            if (value) |bytes| {
                body = body ++ std.mem.toBytes(std.mem.nativeToBig(u32, bytes.len)) ++ bytes;
            } else body = body ++ std.mem.toBytes(std.mem.nativeToBig(i32, -1));
        }
        const message = "D" ++ std.mem.toBytes(std.mem.nativeToBig(u32, body.len + 4)) ++ body;
        const final = message[0..].*;
        return &final;
    }
}

fn fieldMessage(comptime tag: u8, comptime fields: []const u8) []const u8 {
    const body = fields ++ "\x00";
    return .{tag} ++ std.mem.toBytes(std.mem.nativeToBig(u32, body.len + 4)) ++ body;
}

test "a column longer than the inbox arrives in parts that add up to it, and the row then continues" {
    const long = &@as([pg.max_inline_value_bytes + 1]u8, @splat('y'));
    const input = comptime dataRow(&.{ long, "z" }) ++ hex("5a0000000549");
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try transcript(input, 4096, &output.writer);
    try std.testing.expectEqualStrings(
        \\row 2
        \\value of 16381
        \\part 4085
        \\part 4096
        \\part 4096
        \\part 4096
        \\part 8
        \\value 7a
        \\ready idle
        \\
    , output.written());
    // The longest whole value still arrives whole.
    output.clearRetainingCapacity();
    try transcript(comptime dataRow(&.{&@as([pg.max_inline_value_bytes]u8, @splat('y'))}), 4096, &output.writer);
    try std.testing.expectEqualStrings("row 1\nvalue 7979", output.written()[0..16]);
}

test "notices are skipped at any length and an error keeps its SQLSTATE, severity and the start of its message" {
    const notice = comptime fieldMessage('N', "SNOTICE\x00VNOTICE\x00C00000\x00M" ++ &@as([40_000]u8, @splat('n')) ++ "\x00");
    const failure = comptime fieldMessage('E', "SFEHLER\x00VFATAL\x00C57P01\x00M" ++ &@as([300]u8, @splat('m')) ++ "\x00Dmore\x00");
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try transcript(notice ++ failure, 1000, &output.writer);
    try std.testing.expectEqualStrings("error 57P01 fatal unavailable " ++ &@as([128]u8, @splat('m')) ++ "\n", output.written());
}

test "malformed messages are protocol violations, never misread" {
    const cases = [_][]const u8{
        // A length below its own four bytes.
        comptime hex("5a00000003"),
        // ReadyForQuery with an unknown status.
        comptime hex("5a0000000558"),
        // A DataRow whose column runs past the row.
        comptime hex("440000000a0001000000ff4141"),
        // A DataRow with bytes left after its last column.
        comptime hex("440000000b0001000000004141"),
        // A message type Rui never asks for (CopyInResponse).
        comptime hex("470000000700000000"),
        // An ErrorResponse whose field list is not terminated.
        comptime hex("450000000a43323230313200"),
        // ParameterStatus missing its value's terminator.
        comptime hex("5300000007610062"),
        // A non-row message larger than the inbox.
        comptime hex("5300004001"),
    };
    for (cases) |input| {
        var decoder: pg.Decoder = .{};
        var start: usize = 0;
        const failed = while (start <= input.len) {
            const decoded = decoder.next(input[start..]) catch break true;
            start += decoded.consumed;
            if (decoded.event == null) break false;
        } else false;
        try std.testing.expect(failed);
    }
}

test "SQLSTATEs map to the Store's classes" {
    const cases = [_]struct { []const u8, pg.Class }{
        .{ "08006", .connection },     .{ "57P01", .unavailable },      .{ "53300", .unavailable },
        .{ "28P01", .authentication }, .{ "3D000", .missing_database }, .{ "57014", .timeout },
        .{ "55P03", .timeout },        .{ "40001", .serialization },    .{ "40P01", .serialization },
        .{ "23505", .constraint },     .{ "25006", .read_only },        .{ "RUI01", .guard },
        .{ "42P01", .statement },      .{ "0A000", .statement },        .{ "XX000", .server_fault },
        .{ "58030", .server_fault },   .{ "22012", .other },
    };
    for (cases) |case| try std.testing.expectEqual(case[1], pg.classify(case[0][0..5].*));
}

// ------------------------------------------------------------ startup

const zero_nonce: [18]u8 = @splat(0);

fn localStartup() !pg.Startup {
    return pg.Startup.init(.{ .user = "postgres", .database = "postgres", .password = "", .security = .local, .nonce = zero_nonce });
}

test "a captured local startup reaches ready with the server's version and key" {
    var startup = try localStartup();
    var buffer: [pg.send_buffer_bytes]u8 = undefined;
    var out: pg.Outbox = .{ .buffer = &buffer };
    try startup.begin(&out);
    try std.testing.expectEqualSlices(u8, comptime hex("00000029 00030000") ++ "user\x00postgres\x00database\x00postgres\x00\x00", out.bytes());
    // Every split point gives the same outcome.
    for (1..captured_startup.len) |split| {
        var again = try localStartup();
        var scratch: [64]u8 = undefined;
        var sink: pg.Outbox = .{ .buffer = &scratch };
        again.phase = .startup_sent;
        const first = try again.receive(captured_startup[0..split], &sink);
        try std.testing.expectEqual(pg.Next.read, first.next);
        const second = try again.receive(captured_startup[first.consumed..], &sink);
        try std.testing.expectEqual(pg.Next.ready, second.next);
        try std.testing.expectEqual(captured_startup.len, first.consumed + second.consumed);
        try std.testing.expectEqual(@as(u32, 160015), again.serverVersionNum());
        try std.testing.expectEqual(@as(u32, 0x949), again.backend.pid);
        try std.testing.expectEqual(@as(usize, 0), sink.len);
    }
}

fn scriptedTls(answer: []const u8) pg.StartupError!pg.Next {
    var startup = try pg.Startup.init(.{ .user = "u", .database = "d", .password = "p", .security = .tls, .nonce = zero_nonce });
    var buffer: [256]u8 = undefined;
    var out: pg.Outbox = .{ .buffer = &buffer };
    try startup.begin(&out);
    std.debug.assert(std.mem.eql(u8, comptime hex("0000000804d2162f"), out.bytes()));
    return (try startup.receive(answer, &out)).next;
}

test "TLS startup: a refused or stuffed SSL answer fails before any credential is sent" {
    try std.testing.expectEqual(pg.Next.start_tls, try scriptedTls("S"));
    try std.testing.expectError(error.TlsRefused, scriptedTls("N"));
    try std.testing.expectError(error.TlsRefused, scriptedTls("E"));
    try std.testing.expectError(error.ProtocolViolation, scriptedTls("SR"));
}

/// The outcome of a TLS startup whose server, after the handshake,
/// answers the StartupMessage with `answer`.
fn afterHandshake(answer: []const u8, binding: ?tls.ChannelBinding) pg.StartupError!pg.Step {
    var startup = try pg.Startup.init(.{ .user = "u", .database = "d", .password = "p", .security = .tls, .nonce = zero_nonce });
    var buffer: [512]u8 = undefined;
    var out: pg.Outbox = .{ .buffer = &buffer };
    try startup.begin(&out);
    _ = try startup.receive("S", &out);
    try startup.tlsReady(binding, &out);
    return startup.receive(answer, &out);
}

test "TLS startup: only SCRAM is accepted, and PLUS needs the certificate's hash" {
    const ok = comptime hex("520000000800000000");
    const md5 = comptime hex("520000000c0000000501020304");
    const cleartext = comptime hex("520000000800000003");
    const plus_only = comptime hex("520000001c0000000a534352414d2d5348412d3235362d504c55530000");
    const plain_only = comptime hex("52000000170000000a534352414d2d5348412d3235360000");
    try std.testing.expectError(error.AuthMethodRefused, afterHandshake(ok, null));
    try std.testing.expectError(error.AuthMethodRefused, afterHandshake(md5, null));
    try std.testing.expectError(error.AuthMethodRefused, afterHandshake(cleartext, null));
    try std.testing.expectError(error.AuthMethodRefused, afterHandshake(plus_only, null));
    var binding: tls.ChannelBinding = .{ .buffer = @splat(1), .len = 32 };
    try std.testing.expectEqual(pg.Next.read, (try afterHandshake(plus_only, binding)).next);
    try std.testing.expectEqual(pg.Next.read, (try afterHandshake(plain_only, null)).next);
    binding.len = 48;
    try std.testing.expectEqual(pg.Next.read, (try afterHandshake(plain_only, binding)).next);
}

test "TLS startup: a server's error during startup is kept for its class" {
    const refused = comptime fieldMessage('E', "SFATAL\x00VFATAL\x00C28P01\x00Mpassword authentication failed\x00");
    var startup = try pg.Startup.init(.{ .user = "u", .database = "d", .password = "p", .security = .local, .nonce = zero_nonce });
    var buffer: [512]u8 = undefined;
    var out: pg.Outbox = .{ .buffer = &buffer };
    try startup.begin(&out);
    try std.testing.expectError(error.ServerRefused, startup.receive(refused, &out));
    try std.testing.expectEqual(pg.Class.authentication, startup.diagnostic.class());
    try std.testing.expectEqualStrings("password authentication failed", startup.diagnostic.message());
}

fn startupWith(comptime version: []const u8, comptime encoding: []const u8) pg.StartupError!pg.Next {
    const status = struct {
        fn of(comptime name: []const u8, comptime value: []const u8) []const u8 {
            const body = name ++ "\x00" ++ value ++ "\x00";
            return "S" ++ std.mem.toBytes(std.mem.nativeToBig(u32, body.len + 4)) ++ body;
        }
    }.of;
    const answer = comptime hex("520000000800000000") ++ status("server_version", version) ++ status("server_encoding", encoding) ++
        status("client_encoding", "UTF8") ++ status("integer_datetimes", "on") ++ status("standard_conforming_strings", "on") ++ hex("5a0000000549");
    var startup = try localStartup();
    var buffer: [512]u8 = undefined;
    var out: pg.Outbox = .{ .buffer = &buffer };
    try startup.begin(&out);
    return (try startup.receive(answer, &out)).next;
}

test "startup refuses a server older than 15 or not encoding UTF-8" {
    try std.testing.expectEqual(pg.Next.ready, try startupWith("15.0", "UTF8"));
    try std.testing.expectEqual(pg.Next.ready, try startupWith("18beta1", "UTF8"));
    try std.testing.expectError(error.UnsupportedServerVersion, startupWith("14.13", "UTF8"));
    try std.testing.expectError(error.UnsupportedServerEncoding, startupWith("16.4", "SQL_ASCII"));
}

test "encoders refuse a message that does not fit and write nothing" {
    var buffer: [16]u8 = undefined;
    var out: pg.Outbox = .{ .buffer = &buffer };
    try pg.writeSync(&out);
    try std.testing.expectError(error.NoSpace, pg.writeParse(&out, "s1", "SELECT 1", &.{}));
    try std.testing.expectEqual(@as(usize, 5), out.len);
    try std.testing.expectError(error.NoSpace, pg.writeBind(&out, "s1", &.{"0123456789"}));
    try std.testing.expectEqual(@as(usize, 5), out.len);
}

// ------------------------------------------------------------ live

const Live = struct {
    fd: std.c.fd_t,
    context: tls.Context,
    session: tls.Session,
    decoder: pg.Decoder = .{},
    out_buffer: [pg.send_buffer_bytes]u8 = undefined,
    out: pg.Outbox = undefined,
    inbox: [pg.receive_buffer_bytes]u8 = undefined,
    in_start: usize = 0,
    in_end: usize = 0,
    cipher_in: [pg.receive_buffer_bytes]u8 = undefined,
    cipher_len: usize = 0,
    cipher_out: [pg.send_buffer_bytes]u8 = undefined,
    server_version_num: u32 = 0,
    channel_bound: bool = false,
    refusal: pg.Diagnostic = .{},

    const Config = struct { port: u16, password: []const u8, ca_file: []const u8 };

    fn config(environ: *const std.process.Environ.Map) !?Config {
        const required = if (environ.get("RUI_TEST_REQUIRE_ENGINES")) |list| std.mem.indexOf(u8, list, "postgres") != null else false;
        const port = environ.get("RUI_TEST_PG_PORT") orelse return if (required) error.PostgresRequired else null;
        return .{
            .port = try std.fmt.parseUnsigned(u16, port, 10),
            .password = environ.get("RUI_TEST_PG_PASSWORD") orelse return error.PostgresRequired,
            .ca_file = environ.get("RUI_TEST_PG_CA_FILE") orelse return error.PostgresRequired,
        };
    }

    fn open(self: *Live, cfg: Config, password: []const u8) !void {
        self.out = .{ .buffer = &self.out_buffer };
        self.fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (self.fd < 0) return error.Socket;
        errdefer _ = std.c.close(self.fd);
        var address: std.c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, cfg.port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (std.c.connect(self.fd, @ptrCast(&address), @sizeOf(std.c.sockaddr.in)) != 0) return error.Connect;
        // A stalled exchange fails the test instead of hanging it.
        const timeout: std.c.timeval = .{ .sec = 10, .usec = 0 };
        _ = std.c.setsockopt(self.fd, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, @ptrCast(&timeout), @sizeOf(std.c.timeval));
        self.context = try tls.Context.init(.{ .ca_file = cfg.ca_file });
        errdefer self.context.deinit();
        self.session = try tls.Session.init(&self.context, "127.0.0.1", .ip_literal);
        errdefer self.session.deinit();

        var nonce: [18]u8 = undefined;
        std.testing.io.random(&nonce);
        var startup = try pg.Startup.init(.{
            .user = "postgres",
            .database = "postgres",
            .password = password,
            .security = .tls,
            .settings = &.{ .{ "client_encoding", "UTF8" }, .{ "application_name", "rui-wire-test" } },
            .nonce = nonce,
        });
        try startup.begin(&self.out);
        try self.sendRaw(self.out.bytes());
        self.out.len = 0;
        var answer: [1]u8 = undefined;
        if (std.c.recv(self.fd, &answer, 1, 0) != 1) return error.ConnectionLost;
        std.debug.assert((try startup.receive(&answer, &self.out)).next == .start_tls);
        try self.handshake();
        try startup.tlsReady(self.session.channelBinding(), &self.out);
        try self.flush();
        while (true) {
            const step = startup.receive(self.inbox[self.in_start..self.in_end], &self.out) catch |err| {
                self.refusal = startup.diagnostic;
                return err;
            };
            self.in_start += step.consumed;
            try self.flush();
            switch (step.next) {
                .read => try self.fill(),
                .ready => break,
                .start_tls => unreachable,
            }
        }
        self.server_version_num = startup.serverVersionNum();
        self.channel_bound = startup.scram.binding == .server_end_point;
    }

    fn close(self: *Live) void {
        pg.writeTerminate(&self.out) catch {};
        self.flush() catch {};
        self.session.deinit();
        self.context.deinit();
        _ = std.c.close(self.fd);
    }

    fn sendRaw(self: *Live, bytes: []const u8) !void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const count = std.c.send(self.fd, bytes[sent..].ptr, bytes.len - sent, 0);
            if (count <= 0) return error.ConnectionLost;
            sent += @intCast(count);
        }
    }

    fn receiveCipher(self: *Live) !void {
        if (self.cipher_len == self.cipher_in.len) return error.CipherBufferFull;
        const count = std.c.recv(self.fd, self.cipher_in[self.cipher_len..].ptr, self.cipher_in.len - self.cipher_len, 0);
        if (count <= 0) return error.ConnectionLost;
        self.cipher_len += @intCast(count);
    }

    /// Sends what OpenSSL wrote and drops the ciphertext it read.
    fn settle(self: *Live, wire: *const tls.Wire) !void {
        try self.sendRaw(wire.out[0..wire.out_used]);
        std.mem.copyForwards(u8, &self.cipher_in, self.cipher_in[wire.in_used..self.cipher_len]);
        self.cipher_len -= wire.in_used;
    }

    fn handshake(self: *Live) !void {
        while (true) {
            var wire: tls.Wire = .{ .in = self.cipher_in[0..self.cipher_len], .out = &self.cipher_out };
            const progress = self.session.handshake(&wire);
            try self.settle(&wire);
            switch (progress) {
                .done => return,
                .want_read => try self.receiveCipher(),
                .want_write => {},
                .untrusted_peer => return error.UntrustedPeer,
                .failed => return error.TlsFailed,
            }
        }
    }

    fn flush(self: *Live) !void {
        while (self.out.len > 0) {
            var wire: tls.Wire = .{ .in = &.{}, .out = &self.cipher_out };
            const transfer = self.session.write(&wire, self.out.bytes());
            try self.sendRaw(wire.out[0..wire.out_used]);
            switch (transfer) {
                .bytes => |count| self.out.discard(count),
                .want_write => {},
                .want_read, .closed => return error.ConnectionLost,
            }
        }
    }

    /// Reads more plaintext behind the unconsumed bytes, moved to the front.
    fn fill(self: *Live) !void {
        std.mem.copyForwards(u8, &self.inbox, self.inbox[self.in_start..self.in_end]);
        self.in_end -= self.in_start;
        self.in_start = 0;
        while (true) {
            var wire: tls.Wire = .{ .in = self.cipher_in[0..self.cipher_len], .out = &self.cipher_out };
            const transfer = self.session.read(&wire, self.inbox[self.in_end..]);
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

    fn next(self: *Live) !pg.Event {
        while (true) {
            const decoded = try self.decoder.next(self.inbox[self.in_start..self.in_end]);
            self.in_start += decoded.consumed;
            if (decoded.event) |event| return event;
            try self.fill();
        }
    }

    /// Flushes and reads to ReadyForQuery, one line per event.
    fn round(self: *Live, writer: *std.Io.Writer) !void {
        try self.flush();
        while (true) {
            const event = try self.next();
            try describe(event, writer);
            if (event == .message and event.message == .ready_for_query) return;
        }
    }
};

fn liveConfig() !?Live.Config {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const cfg = try Live.config(&environ) orelse return null;
    // The map's strings die with it; tests only need them while it lives,
    // so keep copies in static storage.
    const static = struct {
        var password: [128]u8 = undefined;
        var ca_file: [std.posix.PATH_MAX]u8 = undefined;
    };
    @memcpy(static.password[0..cfg.password.len], cfg.password);
    @memcpy(static.ca_file[0..cfg.ca_file.len], cfg.ca_file);
    return .{ .port = cfg.port, .password = static.password[0..cfg.password.len], .ca_file = static.ca_file[0..cfg.ca_file.len] };
}

fn openLive(password: ?[]const u8) !?*Live {
    const cfg = try liveConfig() orelse return null;
    const live = try std.testing.allocator.create(Live);
    errdefer std.testing.allocator.destroy(live);
    live.* = .{ .fd = -1, .context = undefined, .session = undefined };
    try live.open(cfg, password orelse cfg.password);
    return live;
}

fn closeLive(live: *Live) void {
    live.close();
    std.testing.allocator.destroy(live);
}

test "live: TLS and SCRAM-SHA-256-PLUS reach a ready session on Postgres 15 or later" {
    const live = try openLive(null) orelse return error.SkipZigTest;
    defer closeLive(live);
    try std.testing.expect(live.server_version_num >= 150000);
    try std.testing.expect(live.channel_bound);
    try pg.writeQuery(&live.out, "SELECT 1");
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try live.round(&output.writer);
    try std.testing.expectEqualStrings("columns 1: ?column?/23/0\nrow 1\nvalue 31\ncomplete SELECT 1 rows 1\nready idle\n", output.written());
}

test "live: a wrong password is refused with the authentication class" {
    const cfg = try liveConfig() orelse return error.SkipZigTest;
    const live = try std.testing.allocator.create(Live);
    defer std.testing.allocator.destroy(live);
    live.* = .{ .fd = -1, .context = undefined, .session = undefined };
    try std.testing.expectError(error.ServerRefused, live.open(cfg, "not-the-password"));
    try std.testing.expectEqual(pg.Class.authentication, live.refusal.class());
    try std.testing.expectEqual(pg.Severity.fatal, live.refusal.severity());
}

test "live: a pipelined round answers every statement in order, binary both ways" {
    const live = try openLive(null) orelse return error.SkipZigTest;
    defer closeLive(live);
    const out = &live.out;
    try pg.writeParse(out, "s1", "SELECT $1::int8 + 1, $2::text, NULL::int4", &.{ 20, 25 });
    try pg.writeDescribeStatement(out, "s1");
    for ([_]i64{ 41, -2 }) |number| {
        try pg.writeBind(out, "s1", &.{ &std.mem.toBytes(std.mem.nativeToBig(i64, number)), "é" });
        try pg.writeExecute(out);
    }
    try pg.writeSync(out);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try live.round(&output.writer);
    try std.testing.expectEqualStrings(
        \\parse_complete
        \\parameters 20 25
        \\columns 3: ?column?/20/0 text/25/0 int4/23/0
        \\bind_complete
        \\row 3
        \\value 000000000000002a
        \\value c3a9
        \\value null
        \\complete SELECT 1 rows 1
        \\bind_complete
        \\row 3
        \\value ffffffffffffffff
        \\value c3a9
        \\value null
        \\complete SELECT 1 rows 1
        \\ready idle
        \\
    , output.written());
}

test "live: an error skips the rest of the pipeline to Sync, and COMMIT behind it never commits" {
    const live = try openLive(null) orelse return error.SkipZigTest;
    defer closeLive(live);
    const out = &live.out;
    try pg.writeQuery(out, "CREATE TEMP TABLE wire_probe (n int)");
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try live.round(&output.writer);
    output.clearRetainingCapacity();
    for ([_][]const u8{ "BEGIN", "INSERT INTO wire_probe VALUES (1)", "SELECT 1/0", "INSERT INTO wire_probe VALUES (2)", "COMMIT" }) |sql| {
        try pg.writeParse(out, "", sql, &.{});
        try pg.writeBind(out, "", &.{});
        try pg.writeExecute(out);
    }
    try pg.writeSync(out);
    try live.round(&output.writer);
    try std.testing.expectEqualStrings(
        \\parse_complete
        \\bind_complete
        \\complete BEGIN rows null
        \\parse_complete
        \\bind_complete
        \\complete INSERT 0 1 rows 1
        \\parse_complete
        \\error 22012 err other division by zero
        \\ready failed
        \\
    , output.written());
    output.clearRetainingCapacity();
    try pg.writeQuery(out, "ROLLBACK; SELECT count(*) FROM wire_probe");
    try live.round(&output.writer);
    try std.testing.expectEqualStrings("complete ROLLBACK rows null\ncolumns 1: count/20/0\nrow 1\nvalue 30\ncomplete SELECT 1 rows 1\nready idle\n", output.written());
}

test "live: a bound value larger than the outbox streams through it, and a long result arrives in parts" {
    const live = try openLive(null) orelse return error.SkipZigTest;
    defer closeLive(live);
    const out = &live.out;
    const body = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(body);
    for (body, 0..) |*byte, index| byte.* = @truncate(index *% 31);
    try pg.writeParse(out, "", "SELECT length($1::bytea), md5($1::bytea), $1::bytea", &.{17});
    try pg.writeDescribeStatement(out, "");
    try pg.beginBindStreamed(out, "", &.{}, @intCast(body.len));
    var sent: usize = 0;
    while (sent < body.len) {
        sent += out.appendPart(body[sent..]);
        if (sent < body.len) try live.flush();
    }
    pg.endBindStreamed(out) catch {
        try live.flush();
        try pg.endBindStreamed(out);
    };
    try pg.writeExecute(out);
    try pg.writeSync(out);
    try live.flush();

    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(body, &digest, .{});
    var echoed = std.crypto.hash.Md5.init(.{});
    var parts_len: usize = 0;
    var events: std.ArrayList([]const u8) = .empty;
    defer events.deinit(std.testing.allocator);
    while (true) {
        const event = try live.next();
        switch (event) {
            .value_part => |part| {
                echoed.update(part);
                parts_len += part.len;
            },
            .value => |value| try events.append(std.testing.allocator, if (value) |bytes| try std.fmt.allocPrint(std.testing.allocator, "{x}", .{bytes}) else "null"),
            .message => |message| if (message == .ready_for_query) break,
            else => {},
        }
    }
    defer for (events.items) |item| std.testing.allocator.free(item);
    try std.testing.expectEqual(body.len, parts_len);
    var echoed_digest: [16]u8 = undefined;
    echoed.final(&echoed_digest);
    try std.testing.expectEqualSlices(u8, &digest, &echoed_digest);
    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expectEqualStrings("00020000", events.items[0]);
    var digest_hex: [32]u8 = undefined;
    _ = try std.fmt.bufPrint(&digest_hex, "{x}", .{&digest});
    var md5_text: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&md5_text, "{x}", .{&digest_hex});
    try std.testing.expectEqualStrings(&md5_text, events.items[1]);
}
