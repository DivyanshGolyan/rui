//! TLS for h2 connections. Internal. One `SSL_CTX` per Client, built by its
//! first `https://` endpoint; each connection's `SSL` comes from it.
//!
//! Verification is never off: there is no option or code path that sets
//! SSL_VERIFY_NONE. The handshake verifies the chain against the trust
//! store and the host name or IP literal against the leaf.
//!
//! OpenSSL reaches the socket through a BIO of ours, so each send carries
//! MSG_NOSIGNAL (SO_NOSIGPIPE on Darwin): a peer that went away is
//! an error for one connection, never a SIGPIPE for the process.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("h2_c");
const h2 = @import("h2.zig");

/// Host CA bundles, probed in this order when the context is built, at run
/// time so a cross-built or relocated binary still finds the host's bundle.
/// macOS reads /etc/ssl/cert.pem only until SecTrust lands, which Rui's
/// platform contract requires before the client serves any provider.
pub const system_bundles = [_][:0]const u8{
    "/etc/ssl/certs/ca-certificates.crt", // Debian, Ubuntu, Arch, Alpine
    "/etc/pki/tls/certs/ca-bundle.crt", // Fedora, RHEL
    "/etc/ssl/ca-bundle.pem", // openSUSE
    "/etc/pki/tls/cacert.pem", // OpenELEC
    "/etc/ssl/cert.pem", // macOS, some minimal images
};

const alpn_h2 = "\x02h2";

pub const HostKind = enum { dns_name, ip_literal };

/// For a socket send that must not raise SIGPIPE.
pub const send_flags: c_int = if (builtin.os.tag == .linux) std.c.MSG.NOSIGNAL else 0;

pub const Context = struct {
    ctx: *c.SSL_CTX,
    bio_method: *c.BIO_METHOD,

    /// TLS 1.2 or later; ALPN `h2` only; no session cache, so every
    /// connection verifies the peer afresh; RELEASE_BUFFERS, so an idle
    /// connection holds no OpenSSL record buffers; partial writes from a
    /// moving buffer, for nghttp2's frame buffer.
    pub fn init(trust: h2.Trust) h2.EndpointError!Context {
        const ctx = c.SSL_CTX_new(c.TLS_client_method()) orelse return error.OutOfMemory;
        errdefer c.SSL_CTX_free(ctx);
        if (c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_2_VERSION) != 1) return error.OutOfMemory;
        c.SSL_CTX_set_verify(ctx, c.SSL_VERIFY_PEER, null);
        _ = c.SSL_CTX_set_mode(ctx, c.SSL_MODE_RELEASE_BUFFERS | c.SSL_MODE_ENABLE_PARTIAL_WRITE | c.SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
        _ = c.SSL_CTX_set_session_cache_mode(ctx, c.SSL_SESS_CACHE_OFF);
        // SSL_OP_NO_TICKET; its macro does not translate.
        _ = c.SSL_CTX_set_options(ctx, @as(u64, 1) << 14);
        // Inverted convention: 0 is success.
        if (c.SSL_CTX_set_alpn_protos(ctx, alpn_h2, alpn_h2.len) != 0) return error.OutOfMemory;
        try loadTrust(ctx, trust);
        const bio_method = newBioMethod() orelse return error.OutOfMemory;
        return .{ .ctx = ctx, .bio_method = bio_method };
    }

    pub fn deinit(self: *Context) void {
        c.SSL_CTX_free(self.ctx);
        c.BIO_meth_free(self.bio_method);
        self.* = undefined;
    }

    /// A client session on `fd`, verifying `host`: SNI and the name check
    /// for a DNS name, the IP check (and no SNI) for an IP literal.
    pub fn newSession(self: *const Context, fd: std.posix.fd_t, host: []const u8, kind: HostKind) ?*c.SSL {
        var host_z: [h2.max_host_bytes + 1]u8 = undefined;
        @memcpy(host_z[0..host.len], host);
        host_z[host.len] = 0;
        const ssl = c.SSL_new(self.ctx) orelse return null;
        if (!attachSocket(ssl, self.bio_method, fd)) {
            c.SSL_free(ssl);
            return null;
        }
        const named = if (kind == .ip_literal)
            c.X509_VERIFY_PARAM_set1_ip_asc(c.SSL_get0_param(ssl), &host_z) == 1
        else
            c.SSL_set_tlsext_host_name(ssl, &host_z) == 1 and c.SSL_set1_host(ssl, &host_z) == 1;
        if (!named) {
            c.SSL_free(ssl);
            return null;
        }
        c.SSL_set_connect_state(ssl);
        return ssl;
    }
};

fn loadTrust(ctx: *c.SSL_CTX, trust: h2.Trust) h2.EndpointError!void {
    defer c.ERR_clear_error();
    switch (trust) {
        .ca_file => |path| {
            var path_z: [std.posix.PATH_MAX]u8 = undefined;
            if (path.len >= path_z.len) return error.InvalidCaFile;
            @memcpy(path_z[0..path.len], path);
            path_z[path.len] = 0;
            if (c.SSL_CTX_load_verify_file(ctx, &path_z) != 1) return error.InvalidCaFile;
        },
        .system => {
            for (system_bundles) |path| {
                if (std.c.access(path, std.c.R_OK) != 0) continue;
                if (c.SSL_CTX_load_verify_file(ctx, path) == 1) return;
            }
            return error.TrustUnavailable;
        },
    }
}

// ------------------------------------------------------------ handshake

pub const Progress = union(enum) {
    done,
    want_read,
    want_write,
    failed: @import("policy.zig").Cause,
};

/// One nonblocking handshake step. Done means verified and ALPN `h2`.
pub fn handshake(ssl: *c.SSL) Progress {
    c.ERR_clear_error();
    const result = c.SSL_do_handshake(ssl);
    if (result == 1) {
        var selected: [*c]const u8 = null;
        var selected_len: c_uint = 0;
        c.SSL_get0_alpn_selected(ssl, &selected, &selected_len);
        if (selected_len != 2 or !std.mem.eql(u8, selected[0..2], "h2")) return .{ .failed = .h2_refused };
        return .done;
    }
    return switch (c.SSL_get_error(ssl, result)) {
        c.SSL_ERROR_WANT_READ => .want_read,
        c.SSL_ERROR_WANT_WRITE => .want_write,
        else => .{ .failed = if (c.SSL_get_verify_result(ssl) != c.X509_V_OK) .untrusted_peer else .tls_failed },
    };
}

pub const Transfer = union(enum) {
    bytes: usize,
    want_read,
    want_write,
    closed,
};

pub fn read(ssl: *c.SSL, buffer: []u8) Transfer {
    c.ERR_clear_error();
    var count: usize = 0;
    if (c.SSL_read_ex(ssl, buffer.ptr, buffer.len, &count) == 1) return .{ .bytes = count };
    return status(ssl);
}

pub fn write(ssl: *c.SSL, bytes: []const u8) Transfer {
    c.ERR_clear_error();
    var count: usize = 0;
    if (c.SSL_write_ex(ssl, bytes.ptr, bytes.len, &count) == 1) return .{ .bytes = count };
    return status(ssl);
}

/// After a failed SSL_read_ex or SSL_write_ex, which return 0.
fn status(ssl: *c.SSL) Transfer {
    return switch (c.SSL_get_error(ssl, 0)) {
        c.SSL_ERROR_WANT_READ => .want_read,
        c.SSL_ERROR_WANT_WRITE => .want_write,
        else => .closed,
    };
}

// ------------------------------------------------------------ socket BIO

/// A source/sink BIO over a nonblocking socket. Also used by the test peer.
pub fn newBioMethod() ?*c.BIO_METHOD {
    const method = c.BIO_meth_new(c.BIO_get_new_index() | c.BIO_TYPE_SOURCE_SINK, "h2 socket") orelse return null;
    if (c.BIO_meth_set_write(method, bioWrite) != 1 or
        c.BIO_meth_set_read(method, bioRead) != 1 or
        c.BIO_meth_set_ctrl(method, bioCtrl) != 1 or
        c.BIO_meth_set_create(method, bioCreate) != 1)
    {
        c.BIO_meth_free(method);
        return null;
    }
    return method;
}

/// The SSL owns the BIO from here; it never closes `fd`.
pub fn attachSocket(ssl: *c.SSL, method: *c.BIO_METHOD, fd: std.posix.fd_t) bool {
    const bio = c.BIO_new(method) orelse return false;
    c.BIO_set_data(bio, @ptrFromInt(@as(usize, @intCast(fd)) + 1));
    // One BIO for both directions consumes one reference.
    c.SSL_set_bio(ssl, bio, bio);
    return true;
}

fn socketOf(bio: ?*c.BIO) std.posix.fd_t {
    return @intCast(@intFromPtr(c.BIO_get_data(bio)) - 1);
}

fn bioWrite(bio: ?*c.BIO, data: [*c]const u8, length: c_int) callconv(.c) c_int {
    c.BIO_clear_flags(bio, c.BIO_FLAGS_RWS | c.BIO_FLAGS_SHOULD_RETRY);
    while (true) {
        const sent = std.c.send(socketOf(bio), data, @intCast(length), send_flags);
        if (sent >= 0) return @intCast(sent);
        switch (std.posix.errno(sent)) {
            .INTR => continue,
            .AGAIN => c.BIO_set_flags(bio, c.BIO_FLAGS_WRITE | c.BIO_FLAGS_SHOULD_RETRY),
            else => {},
        }
        return -1;
    }
}

fn bioRead(bio: ?*c.BIO, buffer: [*c]u8, length: c_int) callconv(.c) c_int {
    c.BIO_clear_flags(bio, c.BIO_FLAGS_RWS | c.BIO_FLAGS_SHOULD_RETRY);
    while (true) {
        const received = std.c.recv(socketOf(bio), buffer, @intCast(length), 0);
        if (received >= 0) return @intCast(received);
        switch (std.posix.errno(received)) {
            .INTR => continue,
            .AGAIN => c.BIO_set_flags(bio, c.BIO_FLAGS_READ | c.BIO_FLAGS_SHOULD_RETRY),
            else => {},
        }
        return -1;
    }
}

fn bioCtrl(_: ?*c.BIO, command: c_int, _: c_long, _: ?*anyopaque) callconv(.c) c_long {
    return @intFromBool(command == c.BIO_CTRL_FLUSH);
}

fn bioCreate(bio: ?*c.BIO) callconv(.c) c_int {
    c.BIO_set_init(bio, 1);
    return 1;
}
