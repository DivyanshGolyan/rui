const std = @import("std");
const os = @import("os");

pub const c = @import("openssl_c");

pub const max_host_bytes = @import("url").max_host_bytes;

pub const Trust = union(enum) {
    system,
    ca_file: []const u8,
};

pub const TrustError = error{ TrustUnavailable, InvalidCaFile, InvalidSslCertFile, InvalidSslCertDir };

pub const HostKind = enum { dns_name, ip_literal };

/// Linux hashed certificate directories, probed in this order before the
/// bundles. OpenSSL reads a root from one only when a peer's chain names it,
/// where a bundle is parsed whole when trust loads.
pub const system_directories = [_][:0]const u8{
    "/etc/ssl/certs",
    "/etc/pki/tls/certs",
};

pub const system_bundles = [_][:0]const u8{
    "/etc/ssl/certs/ca-certificates.crt",
    "/etc/pki/tls/certs/ca-bundle.crt",
    "/etc/ssl/ca-bundle.pem",
    "/etc/pki/tls/cacert.pem",
    "/etc/ssl/cert.pem",
};

/// TLS 1.2 suites, all AEAD with ephemeral keys (RFC 9113 9.2.2). TLS 1.3
/// suites are set apart and already qualify.
const tls12_ciphers = "ECDHE+AESGCM:ECDHE+CHACHA20";
// SSL_OP_NO_TICKET and SSL_OP_NO_RENEGOTIATION; their macros do not translate.
const no_ticket: u64 = 1 << 14;
pub const no_renegotiation: u64 = 1 << 30;

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

pub fn nameHost(ssl: *c.SSL, host_z: [*:0]const u8, kind: HostKind, deferred: bool) bool {
    const named = if (kind == .ip_literal)
        deferred or c.X509_VERIFY_PARAM_set1_ip_asc(c.SSL_get0_param(ssl), host_z) == 1
    else
        c.SSL_set_tlsext_host_name(ssl, host_z) == 1 and (deferred or c.SSL_set1_host(ssl, host_z) == 1);
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
            if (os.hashed_trust_directories) for (system_directories) |path| {
                if (!hashedDirectory(path)) continue;
                if (c.SSL_CTX_load_verify_dir(ctx, path) == 1) return;
            };
            for (system_bundles) |path| {
                if (std.c.access(path, std.c.R_OK) != 0) continue;
                if (c.SSL_CTX_load_verify_file(ctx, path) == 1) return;
            }
            return error.TrustUnavailable;
        },
    }
}

fn opensslTrustVariable(name: [*:0]const u8) ?[*:0]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return if (value[0] == 0) null else value;
}

pub noinline fn hashedDirectory(path: [:0]const u8) bool {
    const directory = std.c.opendir(path) orelse return false;
    defer _ = std.c.closedir(directory);
    while (std.c.readdir(directory)) |entry| {
        const name = std.mem.sliceTo(&entry.name, 0);
        if (!isSubjectHashName(name)) continue;
        var path_z: [std.posix.PATH_MAX]u8 = undefined;
        const entry_path = std.fmt.bufPrintSentinel(&path_z, "{s}/{s}", .{ path, name }, 0) catch continue;
        if (std.c.access(entry_path, std.c.R_OK) == 0) return true;
    }
    return false;
}

/// Whether `name` is how OpenSSL's directory lookup names a certificate:
/// eight lowercase hex digits of the subject hash, a dot, and a decimal
/// sequence number (`9d04f354.0`). CRLs (`.r0`) and other files do not count.
pub fn isSubjectHashName(name: []const u8) bool {
    if (name.len < 10 or name[8] != '.') return false;
    for (name[0..8]) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    for (name[9..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

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
