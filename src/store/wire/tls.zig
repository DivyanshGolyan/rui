//! TLS for a Store connection, Postgres or MySQL, over the vendored
//! OpenSSL, between caller buffers: OpenSSL reads ciphertext from
//! `Wire.in` and writes it to `Wire.out`, and the connection's owner moves
//! both to and from the socket. Nothing here touches a descriptor.
//!
//! Verification is never off: the chain against the trust and the host
//! name or IP literal against the leaf. The context settings, host naming
//! and trust loading are h2's, so `SSL_CERT_FILE` and the host bundles
//! behave the same for the Store as for providers. On macOS, `.system` is
//! the bundle OpenSSL reads (`/etc/ssl/cert.pem`), not SecTrust.
const std = @import("std");
const h2 = @import("h2");
const shared = h2.openssl_client;
const c = shared.c;

pub const Trust = h2.Trust;
/// Why `Context.init` failed: memory, or trust that would not load.
pub const ContextError = h2.EndpointError;
pub const HostKind = shared.HostKind;

/// Room for one TLS record of a full plaintext fragment (2^14 bytes plus
/// TLS 1.2's largest expansion and the record header), so encrypting one
/// `send_buffer_bytes` outbox never stops halfway for want of room.
pub const max_record_bytes = 16 * 1024 + 2048 + 5;

/// The certificate hash SCRAM-SHA-256-PLUS binds (RFC 5929 section 4.1).
pub const ChannelBinding = @import("scram.zig").ChannelBinding;

/// The ciphertext OpenSSL may read (`in[in_used..]`) and the room it may
/// write (`out[out_used..]`) during one call.
pub const Wire = struct {
    in: []const u8,
    in_used: usize = 0,
    out: []u8,
    out_used: usize = 0,
};

pub const Context = struct {
    ctx: *c.SSL_CTX,
    bio_method: *c.BIO_METHOD,

    pub fn init(trust: Trust) ContextError!Context {
        const ctx = shared.newContext() orelse return error.OutOfMemory;
        errdefer c.SSL_CTX_free(ctx);
        try shared.loadTrust(ctx, trust);
        const method = c.BIO_meth_new(c.BIO_get_new_index() | c.BIO_TYPE_SOURCE_SINK, "store wire") orelse return error.OutOfMemory;
        if (c.BIO_meth_set_write(method, bioWrite) != 1 or
            c.BIO_meth_set_read(method, bioRead) != 1 or
            c.BIO_meth_set_ctrl(method, bioCtrl) != 1 or
            c.BIO_meth_set_create(method, bioCreate) != 1)
        {
            c.BIO_meth_free(method);
            return error.OutOfMemory;
        }
        return .{ .ctx = ctx, .bio_method = method };
    }

    pub fn deinit(self: *Context) void {
        c.SSL_CTX_free(self.ctx);
        c.BIO_meth_free(self.bio_method);
        self.* = undefined;
    }
};

pub const Progress = enum { done, want_read, want_write, untrusted_peer, failed };

pub const Transfer = union(enum) {
    bytes: usize,
    /// More ciphertext must arrive in `Wire.in`.
    want_read,
    /// `Wire.out` is full: send it and call again.
    want_write,
    /// The peer's close_notify, or a fatal TLS error. Either ends the
    /// connection; the Store fences on both alike.
    closed,
};

pub const Session = struct {
    ssl: *c.SSL,
    bio: *c.BIO,

    /// A client session verifying `host`: SNI and the name check for a DNS
    /// name, the IP check (and no SNI) for a literal.
    pub fn init(context: *const Context, host: []const u8, kind: HostKind) error{ OutOfMemory, InvalidHost }!Session {
        var host_z: [h2.max_host_bytes + 1]u8 = undefined;
        if (host.len > h2.max_host_bytes or std.mem.indexOfScalar(u8, host, 0) != null) return error.InvalidHost;
        @memcpy(host_z[0..host.len], host);
        host_z[host.len] = 0;
        const ssl = c.SSL_new(context.ctx) orelse return error.OutOfMemory;
        errdefer c.SSL_free(ssl);
        const bio = c.BIO_new(context.bio_method) orelse return error.OutOfMemory;
        // One BIO for both directions consumes one reference.
        c.SSL_set_bio(ssl, bio, bio);
        if (!shared.nameHost(ssl, host_z[0..host.len :0], kind, false)) return error.InvalidHost;
        c.SSL_set_connect_state(ssl);
        return .{ .ssl = ssl, .bio = bio };
    }

    pub fn deinit(self: *Session) void {
        c.SSL_free(self.ssl);
        self.* = undefined;
    }

    pub fn handshake(self: *Session, wire: *Wire) Progress {
        self.attach(wire);
        defer self.detach();
        const result = c.SSL_do_handshake(self.ssl);
        if (result == 1) return .done;
        return switch (c.SSL_get_error(self.ssl, result)) {
            c.SSL_ERROR_WANT_READ => .want_read,
            c.SSL_ERROR_WANT_WRITE => .want_write,
            else => if (c.SSL_get_verify_result(self.ssl) != c.X509_V_OK) .untrusted_peer else .failed,
        };
    }

    /// Encrypts a prefix of `plain` into `wire.out`.
    pub fn write(self: *Session, wire: *Wire, plain: []const u8) Transfer {
        self.attach(wire);
        defer self.detach();
        var count: usize = 0;
        if (c.SSL_write_ex(self.ssl, plain.ptr, plain.len, &count) == 1) return .{ .bytes = count };
        return self.status();
    }

    /// Decrypts from `wire.in` into `plain`.
    pub fn read(self: *Session, wire: *Wire, plain: []u8) Transfer {
        self.attach(wire);
        defer self.detach();
        var count: usize = 0;
        if (c.SSL_read_ex(self.ssl, plain.ptr, plain.len, &count) == 1) return .{ .bytes = count };
        return self.status();
    }

    /// The tls-server-end-point hash of the verified leaf: its signature's
    /// digest, SHA-256 in place of MD5 or SHA-1. Null for a signature with
    /// no separate digest (Ed25519, RSA-PSS), which SCRAM cannot bind; a
    /// server offering only PLUS is then refused.
    pub fn channelBinding(self: *const Session) ?ChannelBinding {
        const cert = c.SSL_get0_peer_certificate(self.ssl) orelse return null;
        var digest_nid: c_int = c.NID_undef;
        if (c.OBJ_find_sigid_algs(c.X509_get_signature_nid(cert), &digest_nid, null) != 1) return null;
        if (digest_nid == c.NID_md5 or digest_nid == c.NID_sha1) digest_nid = c.NID_sha256;
        const digest = c.EVP_get_digestbynid(digest_nid) orelse return null;
        var binding: ChannelBinding = .{ .buffer = undefined, .len = 0 };
        comptime std.debug.assert(binding.buffer.len >= c.EVP_MAX_MD_SIZE);
        var len: c_uint = 0;
        if (c.X509_digest(cert, digest, &binding.buffer, &len) != 1) return null;
        binding.len = @intCast(len);
        return binding;
    }

    fn attach(self: *Session, wire: *Wire) void {
        c.ERR_clear_error();
        c.BIO_set_data(self.bio, wire);
    }

    fn detach(self: *Session) void {
        c.BIO_set_data(self.bio, null);
    }

    /// After a failed SSL_read_ex or SSL_write_ex, which return 0.
    fn status(self: *Session) Transfer {
        return switch (c.SSL_get_error(self.ssl, 0)) {
            c.SSL_ERROR_WANT_READ => .want_read,
            c.SSL_ERROR_WANT_WRITE => .want_write,
            else => .closed,
        };
    }
};

fn wireOf(bio: ?*c.BIO) *Wire {
    return @ptrCast(@alignCast(c.BIO_get_data(bio).?));
}

fn bioWrite(bio: ?*c.BIO, data: [*c]const u8, length: c_int) callconv(.c) c_int {
    c.BIO_clear_flags(bio, c.BIO_FLAGS_RWS | c.BIO_FLAGS_SHOULD_RETRY);
    const wire = wireOf(bio);
    const count = @min(@as(usize, @intCast(length)), wire.out.len - wire.out_used);
    if (count == 0) {
        c.BIO_set_flags(bio, c.BIO_FLAGS_WRITE | c.BIO_FLAGS_SHOULD_RETRY);
        return -1;
    }
    @memcpy(wire.out[wire.out_used..][0..count], data[0..count]);
    wire.out_used += count;
    return @intCast(count);
}

fn bioRead(bio: ?*c.BIO, buffer: [*c]u8, length: c_int) callconv(.c) c_int {
    c.BIO_clear_flags(bio, c.BIO_FLAGS_RWS | c.BIO_FLAGS_SHOULD_RETRY);
    const wire = wireOf(bio);
    const count = @min(@as(usize, @intCast(length)), wire.in.len - wire.in_used);
    if (count == 0) {
        c.BIO_set_flags(bio, c.BIO_FLAGS_READ | c.BIO_FLAGS_SHOULD_RETRY);
        return -1;
    }
    @memcpy(buffer[0..count], wire.in[wire.in_used..][0..count]);
    wire.in_used += count;
    return @intCast(count);
}

fn bioCtrl(_: ?*c.BIO, command: c_int, _: c_long, _: ?*anyopaque) callconv(.c) c_long {
    return @intFromBool(command == c.BIO_CTRL_FLUSH);
}

fn bioCreate(bio: ?*c.BIO) callconv(.c) c_int {
    c.BIO_set_init(bio, 1);
    return 1;
}
