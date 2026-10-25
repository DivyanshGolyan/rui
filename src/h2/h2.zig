//! Rui's HTTP/2 client on nghttp2 and OpenSSL (issue #556).
//!
//! A self-contained build module: it imports nothing from Rui, and Rui
//! reaches it only as `@import("h2")`. A file belongs to one module, so a
//! path import of these files from Rui fails the build.
const std = @import("std");
const c = @import("h2_c");

const policy = @import("policy.zig");

/// The library versions this client is written and tested against.
pub const nghttp2_version = "1.70.0";
pub const openssl_version = "3.6.3";

/// The linked nghttp2 and OpenSSL must be exactly the pinned versions. Its
/// caller runs this at startup, so a build that picked up other headers or
/// archives fails there instead of behaving differently.
pub fn checkLibraries() error{UnexpectedLibraryVersion}!void {
    const nghttp2: *const c.nghttp2_info = c.nghttp2_version(0) orelse return error.UnexpectedLibraryVersion;
    if (!std.mem.eql(u8, std.mem.span(nghttp2.version_str), nghttp2_version)) return error.UnexpectedLibraryVersion;
    const openssl = c.OpenSSL_version(c.OPENSSL_VERSION_STRING) orelse return error.UnexpectedLibraryVersion;
    if (!std.mem.eql(u8, std.mem.span(openssl), openssl_version)) return error.UnexpectedLibraryVersion;
}

test "the linked libraries are the pinned versions" {
    try checkLibraries();
}

test {
    _ = policy;
}
