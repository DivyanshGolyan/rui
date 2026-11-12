//! A content string, such as a Message's text or a tool's output: its size
//! bound and its digest, which together identify it.
const std = @import("std");

/// The most bytes one content string holds. SQLite's length limit is this
/// plus a page of headroom.
pub const max_bytes: u64 = 1024 * 1024 * 1024 - 4096;

/// A content digest in progress, for content that arrives in pieces.
pub fn hasher() std.crypto.hash.sha2.Sha256 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    const domain = "rui/content/v1";
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, domain.len, .big);
    hash.update(&length);
    hash.update(domain);
    return hash;
}

pub fn digest(value: []const u8) [32]u8 {
    var hash = hasher();
    hash.update(value);
    return hash.finalResult();
}
