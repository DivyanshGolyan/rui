//! An HTTP/2 server for the client's own tests: nghttp2's server session on
//! a loopback listener, h2c by prior knowledge or TLS. Single-threaded and
//! nonblocking: a test pumps it between client drives, so every exchange is
//! deterministic and nothing races.
//!
//! A TLS peer generates its own CA and leaf certificate (P-256) at start,
//! and writes the CA to `caPath()` for the client's `.ca_file` trust.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("h2_c");
const tls = @import("../tls.zig");
const Peer = @This();

allocator: std.mem.Allocator,
options: Options,
listener: std.posix.fd_t,
port: u16,
callbacks: *c.nghttp2_session_callbacks,
session_options: *c.nghttp2_option,
connections: std.ArrayList(*Connection),
/// Every request stream in arrival order.
streams: std.ArrayList(*Stream),
seen: Seen,
url_buffer: [96]u8,
url_len: usize,
/// For a TLS peer.
ssl_ctx: ?*c.SSL_CTX,
bio_method: ?*c.BIO_METHOD,
tmp: ?std.testing.TmpDir,
ca_path_buffer: [96]u8,
ca_path_len: usize,

pub const Options = struct {
    tls: enum { none, h2, no_alpn } = .none,
    /// The leaf certificate's subjectAltName.
    leaf_names: [:0]const u8 = "IP:127.0.0.1,DNS:localhost",
    /// Sign the leaf with a CA other than the one written to `caPath()`.
    untrusted_issuer: bool = false,
    /// The host in `url()`.
    url_host: []const u8 = "127.0.0.1",
    max_concurrent_streams: u32 = 100,
    /// Answer the preface as an HTTP/1.1 server would.
    speak_http11: bool = false,
    /// Leave PINGs unanswered.
    ignore_ping: bool = false,
    /// Largest DATA payload the peer sends; 0 for nghttp2's default.
    data_chunk_bytes: usize = 0,
    /// Interleave responses frame by frame (RFC 9218 incremental), instead
    /// of finishing one stream before the next.
    interleave: bool = false,
    /// Runs when a request has fully arrived; null answers 200 "ok".
    on_request: ?*const fn (*Peer, *Stream) void = null,
    context: ?*anyopaque = null,
};

pub const Seen = struct {
    connections: u32 = 0,
    rst_received: u32 = 0,
    pings_received: u32 = 0,
    /// The largest credit the client ever had open to the peer on one stream.
    max_stream_window: i32 = 0,
};

pub const Connection = struct {
    peer: *Peer,
    socket: std.posix.fd_t,
    session: ?*c.nghttp2_session,
    closed: bool,
    received_any: bool,
    ssl: ?*c.SSL,
};

pub const Stream = struct {
    connection: *Connection,
    id: i32,
    index: u32,
    path: std.ArrayList(u8),
    authorization: std.ArrayList(u8),
    body: std.ArrayList(u8),
    complete: bool,
    closed: bool,
    close_code: u32,
    response: []const u8,
    response_offset: usize,
    trailers: bool,
    /// The response head went out; its body never will.
    withhold_body: bool,
};

pub fn start(allocator: std.mem.Allocator, options: Options) !*Peer {
    const self = try allocator.create(Peer);
    errdefer allocator.destroy(self);
    const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.SystemResources;
    errdefer _ = std.c.close(fd);
    try nonblocking(fd);
    var address = std.mem.zeroes(std.c.sockaddr.in);
    address.family = std.c.AF.INET;
    address.addr = std.mem.nativeToBig(u32, 0x7f00_0001);
    if (@hasField(std.c.sockaddr.in, "len")) address.len = @sizeOf(std.c.sockaddr.in);
    if (std.c.bind(fd, @ptrCast(&address), @sizeOf(std.c.sockaddr.in)) != 0) return error.BindFailed;
    if (std.c.listen(fd, 16) != 0) return error.ListenFailed;
    var length: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
    if (std.c.getsockname(fd, @ptrCast(&address), &length) != 0) return error.BindFailed;

    var callbacks: ?*c.nghttp2_session_callbacks = null;
    if (c.nghttp2_session_callbacks_new(&callbacks) != 0) return error.OutOfMemory;
    c.nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks, onBeginHeaders);
    c.nghttp2_session_callbacks_set_on_header_callback2(callbacks, onHeader);
    c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, onDataChunk);
    c.nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, onFrameRecv);
    c.nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, onStreamClose);
    c.nghttp2_session_callbacks_set_data_source_read_length_callback2(callbacks, readLength);
    var session_options: ?*c.nghttp2_option = null;
    if (c.nghttp2_option_new(&session_options) != 0) return error.OutOfMemory;
    if (options.ignore_ping) c.nghttp2_option_set_no_auto_ping_ack(session_options, 1);

    self.* = .{
        .allocator = allocator,
        .options = options,
        .listener = fd,
        .port = std.mem.bigToNative(u16, address.port),
        .callbacks = callbacks.?,
        .session_options = session_options.?,
        .connections = .empty,
        .streams = .empty,
        .seen = .{},
        .url_buffer = undefined,
        .url_len = 0,
        .ssl_ctx = null,
        .bio_method = null,
        .tmp = null,
        .ca_path_buffer = undefined,
        .ca_path_len = 0,
    };
    const scheme = if (options.tls == .none) "http" else "https";
    self.url_len = (try std.fmt.bufPrint(&self.url_buffer, "{s}://{s}:{d}/v1/responses", .{ scheme, options.url_host, self.port })).len;
    if (options.tls != .none) try self.setUpTls();
    return self;
}

pub fn caPath(self: *const Peer) []const u8 {
    return self.ca_path_buffer[0..self.ca_path_len];
}

// --------------------------------------------------------------------- TLS

fn setUpTls(self: *Peer) !void {
    const ca_key = try generateKey();
    defer c.EVP_PKEY_free(ca_key);
    const ca = try certificate(ca_key, null, ca_key, "h2 test CA", &ca_extensions);
    defer c.X509_free(ca);
    // An untrusted leaf has an issuer of the same name but another key.
    const issuer_key = if (self.options.untrusted_issuer) try generateKey() else ca_key;
    defer if (issuer_key != ca_key) c.EVP_PKEY_free(issuer_key);
    const issuer = if (self.options.untrusted_issuer) try certificate(issuer_key, null, issuer_key, "h2 test CA", &ca_extensions) else ca;
    defer if (issuer != ca) c.X509_free(issuer);
    const leaf_key = try generateKey();
    defer c.EVP_PKEY_free(leaf_key);
    const leaf = try certificate(leaf_key, issuer, issuer_key, "h2 test peer", &.{
        .{ c.NID_subject_alt_name, self.options.leaf_names },
        .{ c.NID_basic_constraints, "critical,CA:FALSE" },
        .{ c.NID_key_usage, "critical,digitalSignature" },
        .{ c.NID_ext_key_usage, "serverAuth" },
        .{ c.NID_authority_key_identifier, "keyid:always" },
    });
    defer c.X509_free(leaf);

    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    self.ca_path_len = (try std.fmt.bufPrint(&self.ca_path_buffer, ".zig-cache/tmp/{s}/ca.pem", .{tmp.sub_path})).len;
    var path_z: [@sizeOf(@TypeOf(self.ca_path_buffer)) + 1]u8 = undefined;
    @memcpy(path_z[0..self.ca_path_len], self.caPath());
    path_z[self.ca_path_len] = 0;
    const file = c.BIO_new_file(&path_z, "w") orelse return error.TlsSetupFailed;
    defer _ = c.BIO_free(file);
    if (c.PEM_write_bio_X509(file, ca) != 1) return error.TlsSetupFailed;
    self.tmp = tmp;

    const ctx = c.SSL_CTX_new(c.TLS_server_method()) orelse return error.TlsSetupFailed;
    self.ssl_ctx = ctx;
    if (c.SSL_CTX_use_certificate(ctx, leaf) != 1 or c.SSL_CTX_use_PrivateKey(ctx, leaf_key) != 1) return error.TlsSetupFailed;
    c.SSL_CTX_set_alpn_select_cb(ctx, selectProtocol, self);
    self.bio_method = tls.newBioMethod() orelse return error.TlsSetupFailed;
}

const Extension = struct { c_int, [:0]const u8 };

const ca_extensions = [_]Extension{
    .{ c.NID_basic_constraints, "critical,CA:TRUE" },
    .{ c.NID_key_usage, "critical,keyCertSign,cRLSign" },
    .{ c.NID_subject_key_identifier, "hash" },
};

fn generateKey() !*c.EVP_PKEY {
    const context = c.EVP_PKEY_CTX_new_from_name(null, "EC", null) orelse return error.TlsSetupFailed;
    defer c.EVP_PKEY_CTX_free(context);
    if (c.EVP_PKEY_keygen_init(context) != 1 or c.EVP_PKEY_CTX_set_group_name(context, "P-256") != 1) return error.TlsSetupFailed;
    var key: ?*c.EVP_PKEY = null;
    if (c.EVP_PKEY_generate(context, &key) != 1) return error.TlsSetupFailed;
    return key.?;
}

var next_serial: i64 = 1;

/// Self-signed when `issuer` is null.
fn certificate(key: *c.EVP_PKEY, issuer: ?*c.X509, issuer_key: *c.EVP_PKEY, common_name: [:0]const u8, extensions: []const Extension) !*c.X509 {
    const x509 = c.X509_new() orelse return error.TlsSetupFailed;
    errdefer c.X509_free(x509);
    next_serial += 1;
    if (c.X509_set_version(x509, 2) != 1 or c.ASN1_INTEGER_set_int64(c.X509_get_serialNumber(x509), next_serial) != 1) return error.TlsSetupFailed;
    if (c.X509_time_adj_ex(c.X509_getm_notBefore(x509), -1, 0, null) == null) return error.TlsSetupFailed;
    if (c.X509_time_adj_ex(c.X509_getm_notAfter(x509), 1, 0, null) == null) return error.TlsSetupFailed;
    if (c.X509_set_pubkey(x509, key) != 1) return error.TlsSetupFailed;
    const name = c.X509_get_subject_name(x509);
    if (c.X509_NAME_add_entry_by_txt(name, "CN", c.MBSTRING_ASC, common_name.ptr, -1, -1, 0) != 1) return error.TlsSetupFailed;
    if (c.X509_set_issuer_name(x509, if (issuer) |parent| c.X509_get_subject_name(parent) else name) != 1) return error.TlsSetupFailed;
    var v3 = std.mem.zeroes(c.X509V3_CTX);
    c.X509V3_set_ctx(&v3, issuer orelse x509, x509, null, null, 0);
    for (extensions) |extension| {
        const value = c.X509V3_EXT_conf_nid(null, &v3, extension[0], extension[1].ptr) orelse return error.TlsSetupFailed;
        defer c.X509_EXTENSION_free(value);
        if (c.X509_add_ext(x509, value, -1) != 1) return error.TlsSetupFailed;
    }
    if (c.X509_sign(x509, issuer_key, c.EVP_sha256()) <= 0) return error.TlsSetupFailed;
    return x509;
}

fn selectProtocol(_: ?*c.SSL, out: [*c][*c]const u8, out_len: [*c]u8, offered: [*c]const u8, offered_len: c_uint, argument: ?*anyopaque) callconv(.c) c_int {
    const self: *Peer = @ptrCast(@alignCast(argument.?));
    if (self.options.tls == .no_alpn) return c.SSL_TLSEXT_ERR_NOACK;
    const ours = "\x02h2";
    var selected: [*c]u8 = null;
    if (c.SSL_select_next_proto(&selected, out_len, ours, ours.len, offered, offered_len) != c.OPENSSL_NPN_NEGOTIATED)
        return c.SSL_TLSEXT_ERR_NOACK;
    out.* = selected;
    return c.SSL_TLSEXT_ERR_OK;
}

pub fn url(self: *const Peer) []const u8 {
    return self.url_buffer[0..self.url_len];
}

pub fn stop(self: *Peer) void {
    for (self.connections.items) |connection| {
        self.closeConnection(connection);
        self.allocator.destroy(connection);
    }
    self.connections.deinit(self.allocator);
    for (self.streams.items) |stream| {
        stream.path.deinit(self.allocator);
        stream.authorization.deinit(self.allocator);
        stream.body.deinit(self.allocator);
        self.allocator.destroy(stream);
    }
    self.streams.deinit(self.allocator);
    c.nghttp2_option_del(self.session_options);
    c.nghttp2_session_callbacks_del(self.callbacks);
    if (self.ssl_ctx) |ctx| c.SSL_CTX_free(ctx);
    if (self.bio_method) |method| c.BIO_meth_free(method);
    if (self.tmp) |*tmp| tmp.cleanup();
    _ = std.c.close(self.listener);
    self.allocator.destroy(self);
}

/// Accepts, reads, decodes and writes everything ready, without blocking.
pub fn pump(self: *Peer) !void {
    while (true) {
        const fd = std.c.accept(self.listener, null, null);
        if (fd < 0) break;
        try nonblocking(fd);
        if (builtin.os.tag.isDarwin()) {
            // A client that went away must not SIGPIPE the test process.
            const one: c_int = 1;
            _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, &one, @sizeOf(c_int));
        }
        const connection = try self.allocator.create(Connection);
        connection.* = .{ .peer = self, .socket = fd, .session = null, .closed = false, .received_any = false, .ssl = null };
        if (self.ssl_ctx) |ctx| {
            const ssl = c.SSL_new(ctx) orelse return error.OutOfMemory;
            connection.ssl = ssl;
            if (!tls.attachSocket(ssl, self.bio_method.?, fd)) return error.OutOfMemory;
            c.SSL_set_accept_state(ssl);
        }
        try self.connections.append(self.allocator, connection);
        self.seen.connections += 1;
        if (!self.options.speak_http11) {
            var session: ?*c.nghttp2_session = null;
            if (c.nghttp2_session_server_new3(&session, self.callbacks, connection, self.session_options, null) != 0) return error.OutOfMemory;
            connection.session = session;
            const settings = [_]c.nghttp2_settings_entry{
                .{ .settings_id = c.NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, .value = self.options.max_concurrent_streams },
                .{ .settings_id = c.NGHTTP2_SETTINGS_NO_RFC7540_PRIORITIES, .value = 1 },
            };
            _ = c.nghttp2_submit_settings(session, c.NGHTTP2_FLAG_NONE, &settings, settings.len);
        }
    }
    for (self.connections.items) |connection| {
        if (connection.closed) continue;
        var buffer: [16 * 1024]u8 = undefined;
        while (!connection.closed) {
            const read: usize = switch (receiveSome(connection, &buffer)) {
                .bytes => |count| count,
                .again => break,
                .closed => {
                    self.closeConnection(connection);
                    break;
                },
            };
            if (connection.session == null) {
                // An HTTP/1.1 server's answer to the HTTP/2 preface.
                const answer = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n";
                _ = std.c.send(connection.socket, answer, answer.len, 0);
                self.closeConnection(connection);
                break;
            }
            if (c.nghttp2_session_mem_recv2(connection.session, &buffer, read) < 0) {
                self.closeConnection(connection);
                break;
            }
        }
        if (!connection.closed and connection.session != null) self.flush(connection);
    }
}

/// Waits until the client's socket holds every byte this peer has sent:
/// Darwin delivers loopback segments asynchronously, so a client read
/// right after `pump` can find only some of them.
pub fn awaitDelivery(self: *Peer) !void {
    // SIOCOUTQ and Darwin's SO_NWRITE: bytes sent but not yet acknowledged.
    const siocoutq = 0x5411;
    const so_nwrite = 0x1024;
    for (self.connections.items) |connection| {
        if (connection.closed) continue;
        var waited_ms: u32 = 0;
        while (true) : (waited_ms += 1) {
            var unacknowledged: c_int = 0;
            var size: std.c.socklen_t = @sizeOf(c_int);
            const status = if (builtin.os.tag.isDarwin())
                std.c.getsockopt(connection.socket, std.c.SOL.SOCKET, so_nwrite, @ptrCast(&unacknowledged), &size)
            else
                std.c.ioctl(connection.socket, siocoutq, &unacknowledged);
            if (status != 0) return error.Unexpected;
            if (unacknowledged == 0) break;
            if (waited_ms == 2000) return error.Timeout;
            _ = std.c.poll(&[_]std.c.pollfd{}, 0, 1);
        }
    }
}

const Transfer = union(enum) { bytes: usize, again, closed };

/// Over TLS the first reads also run the server handshake.
fn receiveSome(connection: *Connection, buffer: []u8) Transfer {
    if (connection.ssl) |ssl| return switch (tls.read(ssl, buffer)) {
        .bytes => |count| .{ .bytes = count },
        .want_read, .want_write => .again,
        .closed => .closed,
    };
    const read = std.c.recv(connection.socket, buffer.ptr, buffer.len, 0);
    if (read > 0) return .{ .bytes = @intCast(read) };
    if (read == 0) return .closed;
    return .again;
}

fn sendSome(connection: *Connection, bytes: []const u8) Transfer {
    if (connection.ssl) |ssl| return switch (tls.write(ssl, bytes)) {
        .bytes => |count| .{ .bytes = count },
        .want_read, .want_write => .again,
        .closed => .closed,
    };
    const sent = std.c.send(connection.socket, bytes.ptr, bytes.len, tls.send_flags);
    if (sent >= 0) return .{ .bytes = @intCast(sent) };
    if (std.posix.errno(sent) == .AGAIN) return .again;
    return .closed;
}

fn flush(self: *Peer, connection: *Connection) void {
    // Frames wait for the handshake, which the reads drive.
    if (connection.ssl) |ssl| if (c.SSL_is_init_finished(ssl) != 1) return;
    // nghttp2 hands out one frame at a time. Batched into one send, frames
    // flushed together reach the client in one read: Darwin delivers
    // loopback segments asynchronously, so a send per frame lets a read land
    // between them.
    var batch: [16 * 1024]u8 = undefined;
    var batched: usize = 0;
    while (true) {
        var data: [*c]const u8 = undefined;
        const length: usize = @intCast(@max(0, c.nghttp2_session_mem_send2(connection.session, &data)));
        if (length == 0) break;
        if (batched + length > batch.len) {
            if (!self.sendAll(connection, batch[0..batched])) return;
            batched = 0;
        }
        if (length > batch.len) {
            if (!self.sendAll(connection, data[0..length])) return;
            continue;
        }
        @memcpy(batch[batched..][0..length], data[0..length]);
        batched += length;
    }
    if (!self.sendAll(connection, batch[0..batched])) return;
    for (self.streams.items) |stream| {
        if (stream.connection != connection or stream.closed) continue;
        const window = c.nghttp2_session_get_stream_remote_window_size(connection.session, stream.id);
        self.seen.max_stream_window = @max(self.seen.max_stream_window, window);
    }
}

/// Loopback with small test payloads: a blocking-free full write. False
/// when the connection closed.
fn sendAll(self: *Peer, connection: *Connection, bytes: []const u8) bool {
    var sent: usize = 0;
    while (sent < bytes.len) {
        switch (sendSome(connection, bytes[sent..])) {
            .bytes => |count| sent += count,
            .again => {
                var poll = [_]std.c.pollfd{.{ .fd = connection.socket, .events = std.c.POLL.OUT, .revents = 0 }};
                _ = std.c.poll(&poll, 1, 100);
            },
            .closed => {
                self.closeConnection(connection);
                return false;
            },
        }
    }
    return true;
}

pub fn closeConnection(self: *Peer, connection: *Connection) void {
    _ = self;
    if (connection.closed) return;
    connection.closed = true;
    if (connection.session) |session| c.nghttp2_session_del(session);
    connection.session = null;
    if (connection.ssl) |ssl| c.SSL_free(ssl);
    connection.ssl = null;
    _ = std.c.close(connection.socket);
}

// ------------------------------------------------------------------ actions

pub fn respond(self: *Peer, stream: *Stream, status: u16, body: []const u8) void {
    self.respondWith(stream, status, body, false);
}

/// Responds, then sends a trailer block after the body.
pub fn respondWith(self: *Peer, stream: *Stream, status: u16, body: []const u8, trailers: bool) void {
    _ = self;
    var status_text: [3]u8 = undefined;
    _ = std.fmt.bufPrint(&status_text, "{d}", .{status}) catch unreachable;
    const headers = [_]c.nghttp2_nv{
        nv(":status", &status_text),
        nv("content-type", "text/event-stream"),
    };
    stream.response = body;
    stream.response_offset = 0;
    stream.trailers = trailers;
    const provider: c.nghttp2_data_provider2 = .{ .source = .{ .ptr = stream }, .read_callback = readResponse };
    _ = c.nghttp2_submit_response2(stream.connection.session, stream.id, &headers, headers.len, if (body.len > 0 or trailers) &provider else null);
    if (stream.connection.peer.options.interleave) {
        const incremental: c.nghttp2_extpri = .{ .urgency = 3, .inc = 1 };
        _ = c.nghttp2_session_change_extpri_stream_priority(stream.connection.session, stream.id, &incremental, 1);
    }
}

/// Sends the response head and then nothing more on the stream.
pub fn respondHeadOnly(self: *Peer, stream: *Stream, status: u16) void {
    stream.withhold_body = true;
    self.respondWith(stream, status, "", true);
}

pub fn reset(self: *Peer, stream: *Stream, code: u32) void {
    _ = self;
    _ = c.nghttp2_submit_rst_stream(stream.connection.session, c.NGHTTP2_FLAG_NONE, stream.id, code);
}

pub fn goaway(self: *Peer, connection: *Connection, last_stream_id: i32, code: u32) void {
    _ = self;
    _ = c.nghttp2_submit_goaway(connection.session, c.NGHTTP2_FLAG_NONE, last_stream_id, code, null, 0);
}

fn nv(name: []const u8, value: []const u8) c.nghttp2_nv {
    return .{ .name = @constCast(name.ptr), .value = @constCast(value.ptr), .namelen = name.len, .valuelen = value.len, .flags = c.NGHTTP2_NV_FLAG_NONE };
}

fn nonblocking(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | nonblock) < 0) return error.SystemResources;
}

// ------------------------------------------------------------------ callbacks

fn connectionOf(user_data: ?*anyopaque) *Connection {
    return @ptrCast(@alignCast(user_data.?));
}

fn streamOf(session: ?*c.nghttp2_session, stream_id: i32) ?*Stream {
    return @ptrCast(@alignCast(c.nghttp2_session_get_stream_user_data(session, stream_id)));
}

fn onBeginHeaders(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
    if (frame.*.hd.type != c.NGHTTP2_HEADERS or frame.*.headers.cat != c.NGHTTP2_HCAT_REQUEST) return 0;
    const connection = connectionOf(user_data);
    const peer = connection.peer;
    const stream = peer.allocator.create(Stream) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    stream.* = .{
        .connection = connection,
        .id = frame.*.hd.stream_id,
        .index = @intCast(peer.streams.items.len),
        .path = .empty,
        .authorization = .empty,
        .body = .empty,
        .complete = false,
        .closed = false,
        .close_code = 0,
        .response = &.{},
        .response_offset = 0,
        .trailers = false,
        .withhold_body = false,
    };
    peer.streams.append(peer.allocator, stream) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    _ = c.nghttp2_session_set_stream_user_data(session, stream.id, stream);
    return 0;
}

fn onHeader(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, name: ?*c.nghttp2_rcbuf, value: ?*c.nghttp2_rcbuf, _: u8, user_data: ?*anyopaque) callconv(.c) c_int {
    const stream = streamOf(session, frame.*.hd.stream_id) orelse return 0;
    const allocator = connectionOf(user_data).peer.allocator;
    const name_vec = c.nghttp2_rcbuf_get_buf(name);
    const value_vec = c.nghttp2_rcbuf_get_buf(value);
    const field = name_vec.base[0..name_vec.len];
    const target = if (std.mem.eql(u8, field, ":path")) &stream.path else if (std.mem.eql(u8, field, "authorization")) &stream.authorization else return 0;
    target.appendSlice(allocator, value_vec.base[0..value_vec.len]) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    return 0;
}

fn onDataChunk(session: ?*c.nghttp2_session, _: u8, stream_id: i32, data: [*c]const u8, length: usize, user_data: ?*anyopaque) callconv(.c) c_int {
    const stream = streamOf(session, stream_id) orelse return 0;
    stream.body.appendSlice(connectionOf(user_data).peer.allocator, data[0..length]) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    return 0;
}

fn onFrameRecv(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
    const peer = connectionOf(user_data).peer;
    switch (frame.*.hd.type) {
        c.NGHTTP2_RST_STREAM => peer.seen.rst_received += 1,
        c.NGHTTP2_PING => if (frame.*.hd.flags & c.NGHTTP2_FLAG_ACK == 0) {
            peer.seen.pings_received += 1;
        },
        c.NGHTTP2_HEADERS, c.NGHTTP2_DATA => if (frame.*.hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0) {
            const stream = streamOf(session, frame.*.hd.stream_id) orelse return 0;
            stream.complete = true;
            if (peer.options.on_request) |handler| handler(peer, stream) else peer.respond(stream, 200, "ok");
        },
        else => {},
    }
    return 0;
}

fn onStreamClose(session: ?*c.nghttp2_session, stream_id: i32, code: u32, _: ?*anyopaque) callconv(.c) c_int {
    const stream = streamOf(session, stream_id) orelse return 0;
    stream.closed = true;
    stream.close_code = code;
    return 0;
}

fn readLength(_: ?*c.nghttp2_session, _: u8, _: i32, _: i32, _: i32, max_payload: u32, user_data: ?*anyopaque) callconv(.c) c.nghttp2_ssize {
    const chunk = connectionOf(user_data).peer.options.data_chunk_bytes;
    return @intCast(if (chunk == 0) max_payload else @min(chunk, max_payload));
}

fn readResponse(session: ?*c.nghttp2_session, _: i32, buffer: [*c]u8, length: usize, flags: [*c]u32, source: [*c]c.nghttp2_data_source, _: ?*anyopaque) callconv(.c) c.nghttp2_ssize {
    const stream: *Stream = @ptrCast(@alignCast(source.*.ptr.?));
    if (stream.withhold_body) return c.NGHTTP2_ERR_DEFERRED;
    const count = @min(length, stream.response.len - stream.response_offset);
    @memcpy(buffer[0..count], stream.response[stream.response_offset..][0..count]);
    stream.response_offset += count;
    if (stream.response_offset == stream.response.len) {
        flags.* |= c.NGHTTP2_DATA_FLAG_EOF;
        if (stream.trailers) {
            flags.* |= c.NGHTTP2_DATA_FLAG_NO_END_STREAM;
            const trailer = [_]c.nghttp2_nv{nv("x-trailer", "done")};
            _ = c.nghttp2_submit_trailer(session, stream.id, &trailer, trailer.len);
        }
    }
    return @intCast(count);
}
