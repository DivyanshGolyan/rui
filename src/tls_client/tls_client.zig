//! What every Rui TLS client shares, over the pinned OpenSSL: the client
//! context settings, host naming and trust loading. The HTTP/2 client and
//! the Store's Postgres and MySQL wire each build their own context and
//! sessions from these, so `SSL_CERT_FILE`, `SSL_CERT_DIR`, the host bundles
//! and `--provider-ca-file` mean the same everywhere.
//!
//! A self-contained build module, like h2: it imports nothing from Rui and
//! links OpenSSL, so each binary carries one copy. It holds no verification
//! of its own beyond OpenSSL's: Apple SecTrust, which h2 uses for system
//! trust on macOS, stays with h2.
//!
//! Verification is never off: nothing here sets SSL_VERIFY_NONE.
const std = @import("std");
const builtin = @import("builtin");

/// The pinned OpenSSL's declarations. Every module that calls OpenSSL uses
/// these, so their types are one set.
pub const c = @import("openssl_c");

/// Socket setup and send flags for the Store's wire clients, which cannot
/// reach src/os: Linux's MSG_NOSIGNAL per send, Darwin's SO_NOSIGPIPE once.
pub const socket = struct {
    pub const send_flags: c_int = if (builtin.os.tag == .linux) std.c.MSG.NOSIGNAL else 0;

    /// Close-on-exec, non-blocking, over TCP no Nagle delay, and on Darwin
    /// no SIGPIPE when the peer went away.
    pub fn configure(fd: std.c.fd_t, tcp: bool) bool {
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
};

/// The longest DNS name; IP literals are shorter.
pub const max_host_bytes = 253;

/// What a peer's certificate chain is checked against.
pub const Trust = union(enum) {
    /// OpenSSL's `SSL_CERT_FILE` (a PEM bundle) and `SSL_CERT_DIR`
    /// (colon-separated hashed directories) when either is set and not
    /// empty, read when trust loads; otherwise the first readable bundle
    /// among the host's usual CA bundle paths.
    system,
    /// Only the certificates in this PEM file (`--provider-ca-file`).
    ca_file: []const u8,
};

/// Why trust would not load.
pub const TrustError = error{ TrustUnavailable, InvalidCaFile, InvalidSslCertFile, InvalidSslCertDir };

pub const HostKind = enum { dns_name, ip_literal };

/// Linux host CA bundles, probed in this order when trust loads, at run
/// time so a cross-built or relocated binary still finds the host's bundle.
pub const system_bundles = [_][:0]const u8{
    "/etc/ssl/certs/ca-certificates.crt", // Debian, Ubuntu, Arch, Alpine
    "/etc/pki/tls/certs/ca-bundle.crt", // Fedora, RHEL
    "/etc/ssl/ca-bundle.pem", // openSUSE
    "/etc/pki/tls/cacert.pem", // OpenELEC
    "/etc/ssl/cert.pem", // some minimal images
};

/// TLS 1.2 suites, all AEAD with ephemeral keys (RFC 9113 9.2.2). TLS 1.3
/// suites are set apart and already qualify.
const tls12_ciphers = "ECDHE+AESGCM:ECDHE+CHACHA20";
// SSL_OP_NO_TICKET and SSL_OP_NO_RENEGOTIATION; their macros do not translate.
const no_ticket: u64 = 1 << 14;
pub const no_renegotiation: u64 = 1 << 30;

/// A client context with the settings every Rui TLS connection shares:
/// TLS 1.2 or later with AEAD suites on 1.2, no renegotiation, peer
/// verification, no session cache or tickets, no record buffers held while
/// idle, and partial writes from a moving buffer. The caller adds trust and
/// any ALPN.
pub fn newContext() ?*c.SSL_CTX {
    const ctx = c.SSL_CTX_new(c.TLS_client_method()) orelse return null;
    if (c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_2_VERSION) != 1 or
        c.SSL_CTX_set_cipher_list(ctx, tls12_ciphers) != 1)
    {
        c.SSL_CTX_free(ctx);
        return null;
    }
    c.SSL_CTX_set_verify(ctx, c.SSL_VERIFY_PEER, null);
    _ = c.SSL_CTX_set_mode(ctx, c.SSL_MODE_RELEASE_BUFFERS | c.SSL_MODE_ENABLE_PARTIAL_WRITE | c.SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
    _ = c.SSL_CTX_set_session_cache_mode(ctx, c.SSL_SESS_CACHE_OFF);
    _ = c.SSL_CTX_set_options(ctx, no_ticket | no_renegotiation);
    return ctx;
}

/// Sets what `ssl` verifies `host` against: SNI and the name check for a
/// DNS name, the IP check (and no SNI) for an IP literal. A deferred
/// session's name is checked after the handshake by its owner (h2's
/// SecTrust), not OpenSSL.
pub fn nameHost(ssl: *c.SSL, host_z: [*:0]const u8, kind: HostKind, deferred: bool) bool {
    const named = if (kind == .ip_literal)
        deferred or c.X509_VERIFY_PARAM_set1_ip_asc(c.SSL_get0_param(ssl), host_z) == 1
    else
        c.SSL_set_tlsext_host_name(ssl, host_z) == 1 and (deferred or c.SSL_set1_host(ssl, host_z) == 1);
    // A wildcard covers a whole label (`*.example.com`), never part of one.
    c.SSL_set_hostflags(ssl, c.X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
    return named;
}

pub fn loadTrust(ctx: *c.SSL_CTX, trust: Trust) TrustError!void {
    defer c.ERR_clear_error();
    switch (trust) {
        .ca_file => |path| {
            var path_z: [std.posix.PATH_MAX]u8 = undefined;
            const terminated = std.fmt.bufPrintSentinel(&path_z, "{s}", .{path}, 0) catch return error.InvalidCaFile;
            if (c.SSL_CTX_load_verify_file(ctx, terminated) != 1) return error.InvalidCaFile;
        },
        .system => {
            // OpenSSL's documented overrides. Either one replaces the probe,
            // and a path that cannot be loaded fails instead of falling
            // back, so a wrong setting is never silently ignored.
            const file = opensslTrustVariable("SSL_CERT_FILE");
            const dirs = opensslTrustVariable("SSL_CERT_DIR");
            if (file != null or dirs != null) {
                if (file) |path| if (c.SSL_CTX_load_verify_file(ctx, path) != 1) return error.InvalidSslCertFile;
                if (dirs) |list| {
                    if (!allDirectories(std.mem.span(list))) return error.InvalidSslCertDir;
                    // Looked up by subject hash at verification time.
                    if (c.SSL_CTX_load_verify_dir(ctx, list) != 1) return error.InvalidSslCertDir;
                }
                return;
            }
            for (system_bundles) |path| {
                if (std.c.access(path, std.c.R_OK) != 0) continue;
                if (c.SSL_CTX_load_verify_file(ctx, path) == 1) return;
            }
            return error.TrustUnavailable;
        },
    }
}

/// An OpenSSL trust variable's value, or null when unset or empty.
fn opensslTrustVariable(name: [*:0]const u8) ?[*:0]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return if (value[0] == 0) null else value;
}

/// Whether a colon-separated list, as OpenSSL splits SSL_CERT_DIR, names at
/// least one directory and every element is a directory this process can
/// search, which is all OpenSSL's lookup needs. Empty elements are skipped,
/// as OpenSSL skips them.
/// noinline: trust loads once per context, and this path buffer would
/// otherwise sit in the caller's frame beside loadTrust's own.
noinline fn allDirectories(list: []const u8) bool {
    var paths = std.mem.tokenizeScalar(u8, list, ':');
    var count: usize = 0;
    while (paths.next()) |path| : (count += 1) {
        var path_z: [std.posix.PATH_MAX]u8 = undefined;
        // "<path>/." resolves only for a directory, and X_OK is search.
        const dot = std.fmt.bufPrintSentinel(&path_z, "{s}/.", .{path}, 0) catch return false;
        if (std.c.access(dot, std.c.X_OK) != 0) return false;
    }
    return count > 0;
}
