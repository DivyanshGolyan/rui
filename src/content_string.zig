const std = @import("std");

pub const max_bytes: u64 = 1024 * 1024 * 1024 - 4096;

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
