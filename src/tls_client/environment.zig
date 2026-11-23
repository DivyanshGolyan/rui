//! The environment variables a Host's transport reads. Each reader names its variable from here, and
//! `zig build openapi` writes the same list to clients/ts/src/host-environment.ts, so a client that
//! starts a Host passes on exactly what the transport would read.

/// The proxy a Host tunnels `https://` origins through, and the hosts it reaches directly.
/// A set lowercase name decides, even when empty.
pub const https_proxy = [2][:0]const u8{ "https_proxy", "HTTPS_PROXY" };
pub const no_proxy = [2][:0]const u8{ "no_proxy", "NO_PROXY" };
/// OpenSSL's trust store override on Linux; Apple SecTrust ignores them.
pub const ssl_cert_file: [:0]const u8 = "SSL_CERT_FILE";
pub const ssl_cert_dir: [:0]const u8 = "SSL_CERT_DIR";

pub const all = https_proxy ++ no_proxy ++ [_][:0]const u8{ ssl_cert_file, ssl_cert_dir };
